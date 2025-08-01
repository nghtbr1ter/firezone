use crate::messages::gateway::ResourceDescription;
use crate::messages::{Answer, IceCredentials, ResolveRequest, SecretKey};
use crate::peer::TranslateOutboundResult;
use crate::{GatewayEvent, IpConfig, p2p_control};
use crate::{peer::ClientOnGateway, peer_store::PeerStore};
use anyhow::{Context, Result};
use boringtun::x25519::PublicKey;
use chrono::{DateTime, Utc};
use connlib_model::{ClientId, IceCandidate, RelayId, ResourceId};
use dns_types::DomainName;
use ip_packet::{FzP2pControlSlice, IpPacket};
use secrecy::{ExposeSecret as _, Secret};
use snownet::{Credentials, NoTurnServers, RelaySocket, ServerNode, Transmit};
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::iter;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::time::{Duration, Instant};

pub const TUN_DNS_PORT: u16 = 53535;

const EXPIRE_RESOURCES_INTERVAL: Duration = Duration::from_secs(1);

/// A SANS-IO implementation of a gateway's functionality.
///
/// Internally, this composes a [`snownet::ServerNode`] with firezone's policy engine around resources.
pub struct GatewayState {
    /// The [`snownet::ClientNode`].
    ///
    /// Manages wireguard tunnels to clients.
    node: ServerNode<ClientId, RelayId>,
    /// All clients we are connected to and the associated, connection-specific state.
    peers: PeerStore<ClientId, ClientOnGateway>,

    /// When to next check whether a resource-access policy has expired.
    next_expiry_resources_check: Option<Instant>,

    tun_ip_config: Option<IpConfig>,

    buffered_events: VecDeque<GatewayEvent>,
    buffered_transmits: VecDeque<Transmit>,
}

#[derive(Debug)]
pub struct DnsResourceNatEntry {
    domain: DomainName,
    proxy_ips: Vec<IpAddr>,
    resolved_ips: Vec<IpAddr>,
}

impl DnsResourceNatEntry {
    pub fn new(request: ResolveRequest, resolved_ips: Vec<IpAddr>) -> Self {
        Self {
            domain: request.name,
            proxy_ips: request.proxy_ips,
            resolved_ips,
        }
    }
}

impl GatewayState {
    pub(crate) fn new(seed: [u8; 32], now: Instant) -> Self {
        Self {
            peers: Default::default(),
            node: ServerNode::new(seed, now),
            next_expiry_resources_check: Default::default(),
            buffered_events: VecDeque::default(),
            buffered_transmits: VecDeque::default(),
            tun_ip_config: None,
        }
    }

    #[cfg(all(test, feature = "proptest"))]
    pub(crate) fn tunnel_ip_config(&self) -> Option<IpConfig> {
        self.tun_ip_config
    }

    pub(crate) fn public_key(&self) -> PublicKey {
        self.node.public_key()
    }

    /// Handles packets received on the TUN device.
    pub(crate) fn handle_tun_input(
        &mut self,
        packet: IpPacket,
        now: Instant,
    ) -> Result<Option<snownet::Transmit>> {
        let dst = packet.destination();

        if !crate::is_peer(dst) {
            return Ok(None);
        }

        let Some(peer) = self.peers.peer_by_ip_mut(dst) else {
            tracing::debug!(%dst, "Unknown client, perhaps already disconnected?");
            return Ok(None);
        };
        let cid = peer.id();

        let Some(packet) = peer
            .translate_inbound(packet, now)
            .context("Failed to translate inbound packet")?
        else {
            return Ok(None);
        };

        let Some(encrypted_packet) = self
            .node
            .encapsulate(cid, packet, now)
            .context("Failed to encapsulate")?
        else {
            return Ok(None);
        };

        Ok(Some(encrypted_packet))
    }

    /// Handles UDP packets received on the network interface.
    ///
    /// Most of these packets will be WireGuard encrypted IP packets and will thus yield an [`IpPacket`].
    /// Some of them will however be handled internally, for example, TURN control packets exchanged with relays.
    ///
    /// In case this function returns `None`, you should call [`GatewayState::handle_timeout`] next to fully advance the internal state.
    pub(crate) fn handle_network_input(
        &mut self,
        local: SocketAddr,
        from: SocketAddr,
        packet: &[u8],
        now: Instant,
    ) -> Result<Option<IpPacket>> {
        let Some((cid, packet)) = self
            .node
            .decapsulate(local, from, packet, now)
            .context("Failed to decapsulate")?
        else {
            return Ok(None);
        };

        let peer = self
            .peers
            .get_mut(&cid)
            .with_context(|| format!("No peer for connection {cid}"))?;

        if let Some(fz_p2p_control) = packet.as_fz_p2p_control() {
            let Some(immediate_response) =
                handle_p2p_control_packet(fz_p2p_control, peer, &mut self.buffered_events)
            else {
                return Ok(None);
            };

            let Some(transmit) = encrypt_packet(immediate_response, cid, &mut self.node, now)?
            else {
                return Ok(None);
            };

            self.buffered_transmits.push_back(transmit);

            return Ok(None);
        }

        match peer
            .translate_outbound(packet, now)
            .context("Failed to translate outbound packet")?
        {
            TranslateOutboundResult::Send(ip_packet) => Ok(Some(ip_packet)),
            TranslateOutboundResult::DestinationUnreachable(reply)
            | TranslateOutboundResult::Filtered(reply) => {
                let Some(transmit) = encrypt_packet(reply, cid, &mut self.node, now)? else {
                    return Ok(None);
                };

                self.buffered_transmits.push_back(transmit);

                Ok(None)
            }
        }
    }

    pub fn cleanup_connection(&mut self, id: &ClientId) {
        self.peers.remove(id);
    }

    pub fn add_ice_candidate(
        &mut self,
        conn_id: ClientId,
        ice_candidate: IceCandidate,
        now: Instant,
    ) {
        self.node
            .add_remote_candidate(conn_id, ice_candidate.into(), now);
        self.node.handle_timeout(now);
        self.drain_node_events();
    }

    pub fn remove_ice_candidate(
        &mut self,
        conn_id: ClientId,
        ice_candidate: IceCandidate,
        now: Instant,
    ) {
        self.node
            .remove_remote_candidate(conn_id, ice_candidate.into(), now);
        self.node.handle_timeout(now);
        self.drain_node_events();
    }

    #[tracing::instrument(level = "debug", skip_all, fields(%rid, %cid))]
    pub fn remove_access(&mut self, cid: &ClientId, rid: &ResourceId) {
        let Some(peer) = self.peers.get_mut(cid) else {
            return;
        };

        peer.remove_resource(rid);
        if peer.is_emptied() {
            self.peers.remove(cid);
        }

        tracing::debug!("Access removed");
    }

    pub fn update_resource(&mut self, resource: ResourceDescription) {
        for peer in self.peers.iter_mut() {
            peer.update_resource(&resource);
        }
    }

    /// Accept a connection request from a client.
    #[expect(deprecated, reason = "Will be deleted together with deprecated API")]
    pub fn accept(
        &mut self,
        client_id: ClientId,
        offer: snownet::Offer,
        client: PublicKey,
        now: Instant,
    ) -> Result<Answer, NoTurnServers> {
        let answer = self.node.accept_connection(client_id, offer, client, now)?;

        Ok(Answer {
            username: answer.credentials.username,
            password: answer.credentials.password,
        })
    }

    #[tracing::instrument(level = "debug", skip_all, fields(%cid))]
    #[expect(clippy::too_many_arguments)]
    pub fn authorize_flow(
        &mut self,
        cid: ClientId,
        client_key: PublicKey,
        preshared_key: SecretKey,
        client_ice: IceCredentials,
        gateway_ice: IceCredentials,
        client_tun: IpConfig,
        expires_at: Option<DateTime<Utc>>,
        resource: ResourceDescription,
        now: Instant,
    ) -> Result<(), NoTurnServers> {
        self.node.upsert_connection(
            cid,
            client_key,
            Secret::new(preshared_key.expose_secret().0),
            Credentials {
                username: gateway_ice.username,
                password: gateway_ice.password,
            },
            Credentials {
                username: client_ice.username,
                password: client_ice.password,
            },
            now,
        )?;

        let result = self.allow_access(cid, client_tun, expires_at, resource, None);
        debug_assert!(
            result.is_ok(),
            "`allow_access` should never fail without a `DnsResourceEntry`"
        );

        Ok(())
    }

    pub fn allow_access(
        &mut self,
        client: ClientId,
        client_tun: IpConfig,
        expires_at: Option<DateTime<Utc>>,
        resource: ResourceDescription,
        dns_resource_nat: Option<DnsResourceNatEntry>,
    ) -> anyhow::Result<()> {
        let gateway_tun = self.tun_ip_config.context("TUN device not configured")?;

        let peer = self
            .peers
            .entry(client)
            .or_insert_with(|| ClientOnGateway::new(client, client_tun, gateway_tun));

        peer.add_resource(resource.clone(), expires_at);

        if let Some(entry) = dns_resource_nat {
            peer.setup_nat(
                entry.domain,
                resource.id(),
                BTreeSet::from_iter(entry.resolved_ips),
                BTreeSet::from_iter(entry.proxy_ips),
            )?;
        }

        self.peers.add_ip(&client, &client_tun.v4.into());
        self.peers.add_ip(&client, &client_tun.v6.into());

        Ok(())
    }

    pub fn update_access_authorization_expiry(
        &mut self,
        client: ClientId,
        resource: ResourceId,
        expires_at: DateTime<Utc>,
    ) -> anyhow::Result<()> {
        self.peers
            .get_mut(&client)
            .context("No peer state")?
            .update_resource_expiry(resource, expires_at);

        Ok(())
    }

    pub fn handle_domain_resolved(
        &mut self,
        req: ResolveDnsRequest,
        resolve_result: Result<Vec<IpAddr>, Arc<anyhow::Error>>,
        now: Instant,
    ) -> anyhow::Result<()> {
        use p2p_control::dns_resource_nat;

        let nat_status = resolve_result
            .and_then(|addresses| {
                self.peers
                    .get_mut(&req.client)
                    .context("Unknown peer")?
                    .setup_nat(
                        req.domain.clone(),
                        req.resource,
                        BTreeSet::from_iter(addresses),
                        BTreeSet::from_iter(req.proxy_ips),
                    )?;

                Ok(dns_resource_nat::NatStatus::Active)
            })
            .unwrap_or_else(|e| {
                tracing::warn!("Failed to setup DNS resource NAT: {e:#}");

                dns_resource_nat::NatStatus::Inactive
            });

        let packet = dns_resource_nat::domain_status(req.resource, req.domain, nat_status)?;

        let Some(transmit) = encrypt_packet(packet, req.client, &mut self.node, now)? else {
            return Ok(());
        };

        self.buffered_transmits.push_back(transmit);

        Ok(())
    }

    pub fn poll_timeout(&mut self) -> Option<(Instant, &'static str)> {
        iter::empty()
            // TODO: This should check when the next resource actually expires instead of doing it at a fixed interval.
            .chain(
                self.next_expiry_resources_check
                    .map(|instant| (instant, "resource expiry")),
            )
            .chain(self.node.poll_timeout())
            .min_by_key(|(instant, _)| *instant)
    }

    pub fn handle_timeout(&mut self, now: Instant, utc_now: DateTime<Utc>) {
        self.node.handle_timeout(now);
        self.drain_node_events();

        match self.next_expiry_resources_check {
            Some(next_expiry_resources_check) if now >= next_expiry_resources_check => {
                self.peers.iter_mut().for_each(|p| {
                    p.expire_resources(utc_now);
                    p.handle_timeout(now)
                });
                self.peers.retain(|_, p| !p.is_emptied());

                self.next_expiry_resources_check = Some(now + EXPIRE_RESOURCES_INTERVAL);
            }
            None => self.next_expiry_resources_check = Some(now + EXPIRE_RESOURCES_INTERVAL),
            Some(_) => {}
        }
    }

    fn drain_node_events(&mut self) {
        let mut added_ice_candidates = BTreeMap::<ClientId, BTreeSet<IceCandidate>>::default();
        let mut removed_ice_candidates = BTreeMap::<ClientId, BTreeSet<IceCandidate>>::default();

        while let Some(event) = self.node.poll_event() {
            match event {
                snownet::Event::ConnectionFailed(id) | snownet::Event::ConnectionClosed(id) => {
                    self.peers.remove(&id);
                }
                snownet::Event::NewIceCandidate {
                    connection,
                    candidate,
                } => {
                    added_ice_candidates
                        .entry(connection)
                        .or_default()
                        .insert(candidate.into());
                }
                snownet::Event::InvalidateIceCandidate {
                    connection,
                    candidate,
                } => {
                    removed_ice_candidates
                        .entry(connection)
                        .or_default()
                        .insert(candidate.into());
                }
                snownet::Event::ConnectionEstablished(_) => {}
            }
        }

        for (conn_id, candidates) in added_ice_candidates.into_iter() {
            self.buffered_events
                .push_back(GatewayEvent::AddedIceCandidates {
                    conn_id,
                    candidates,
                })
        }

        for (conn_id, candidates) in removed_ice_candidates.into_iter() {
            self.buffered_events
                .push_back(GatewayEvent::RemovedIceCandidates {
                    conn_id,
                    candidates,
                })
        }
    }

    pub(crate) fn poll_transmit(&mut self) -> Option<snownet::Transmit> {
        self.buffered_transmits
            .pop_front()
            .or_else(|| self.node.poll_transmit())
    }

    pub(crate) fn poll_event(&mut self) -> Option<GatewayEvent> {
        if let Some(ev) = self.buffered_events.pop_front() {
            return Some(ev);
        }

        for peer in self.peers.iter_mut() {
            if let Some(ev) = peer.poll_event() {
                return Some(ev);
            }
        }

        None
    }

    pub fn update_relays(
        &mut self,
        to_remove: BTreeSet<RelayId>,
        to_add: BTreeSet<(RelayId, RelaySocket, String, String, String)>,
        now: Instant,
    ) {
        self.node.update_relays(to_remove, &to_add, now);
        self.drain_node_events()
    }

    pub fn update_tun_device(&mut self, config: IpConfig) {
        self.tun_ip_config = Some(config);
    }

    pub fn retain_authorizations(
        &mut self,
        authorizations: BTreeMap<ClientId, BTreeSet<ResourceId>>,
    ) {
        for (client, resources) in authorizations {
            let Some(client) = self.peers.get_mut(&client) else {
                continue;
            };

            client.retain_authorizations(resources);
        }
    }
}

fn handle_p2p_control_packet(
    fz_p2p_control: FzP2pControlSlice,
    peer: &ClientOnGateway,
    buffered_events: &mut VecDeque<GatewayEvent>,
) -> Option<IpPacket> {
    use p2p_control::dns_resource_nat;

    match fz_p2p_control.event_type() {
        p2p_control::ASSIGNED_IPS_EVENT => {
            let Ok(req) = dns_resource_nat::decode_assigned_ips(fz_p2p_control)
                .inspect_err(|e| tracing::debug!("{e:#}"))
            else {
                return None;
            };

            if !peer.is_allowed(req.resource) {
                tracing::warn!(cid = %peer.id(), rid = %req.resource, "Received `AssignedIpsEvent` for resource that is not allowed");

                let packet = dns_resource_nat::domain_status(
                    req.resource,
                    req.domain,
                    dns_resource_nat::NatStatus::Inactive,
                )
                .inspect_err(|e| tracing::warn!("Failed to create `DomainStatus` packet: {e:#}"))
                .ok()?;

                return Some(packet);
            }

            // TODO: Should we throttle concurrent events for the same domain?

            buffered_events.push_back(GatewayEvent::ResolveDns(ResolveDnsRequest {
                domain: req.domain,
                client: peer.id(),
                resource: req.resource,
                proxy_ips: req.proxy_ips,
            }));
        }
        code => {
            tracing::debug!(code = %code.into_u8(), "Unknown control protocol event");
        }
    }

    None
}

fn encrypt_packet(
    packet: IpPacket,
    cid: ClientId,
    node: &mut ServerNode<ClientId, RelayId>,
    now: Instant,
) -> Result<Option<Transmit>> {
    let transmit = node
        .encapsulate(cid, packet, now)
        .context("Failed to encapsulate")?;

    Ok(transmit)
}

/// Opaque request struct for when a domain name needs to be resolved.
#[derive(Debug)]
pub struct ResolveDnsRequest {
    domain: DomainName,
    client: ClientId,
    resource: ResourceId,
    proxy_ips: Vec<IpAddr>,
}

impl ResolveDnsRequest {
    pub fn domain(&self) -> &DomainName {
        &self.domain
    }
}
