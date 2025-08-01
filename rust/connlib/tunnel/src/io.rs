mod gso_queue;
mod nameserver_set;
mod tcp_dns;
mod udp_dns;

use crate::{device_channel::Device, dns, otel, sockets::Sockets};
use anyhow::{Context as _, Result};
use futures::FutureExt as _;
use futures_bounded::FuturesTupleSet;
use gat_lending_iterator::LendingIterator;
use gso_queue::GsoQueue;
use ip_packet::{Ecn, IpPacket, MAX_FZ_PAYLOAD};
use nameserver_set::NameserverSet;
use socket_factory::{DatagramIn, SocketFactory, TcpSocket, UdpSocket};
use std::{
    collections::{BTreeSet, VecDeque},
    io,
    net::{IpAddr, SocketAddr, SocketAddrV4, SocketAddrV6},
    pin::Pin,
    sync::Arc,
    task::{Context, Poll, ready},
    time::{Duration, Instant},
};
use tracing::Level;
use tun::Tun;

/// How many IP packets we will at most read from the MPSC-channel connected to our TUN device thread.
///
/// Reading IP packets from the channel in batches allows us to process (i.e. encrypt) them as a batch.
/// UDP datagrams of the same size and destination can then be sent in a single syscall using GSO.
///
/// On mobile platforms, we are memory-constrained and thus cannot afford to process big batches of packets.
/// Thus, we limit the batch-size there to 25.
const MAX_INBOUND_PACKET_BATCH: usize = {
    if cfg!(any(target_os = "ios", target_os = "android")) {
        25
    } else {
        100
    }
};

/// Bundles together all side-effects that connlib needs to have access to.
pub struct Io {
    /// The UDP sockets used to send & receive packets from the network.
    sockets: Sockets,
    gso_queue: GsoQueue,

    nameservers: NameserverSet,
    reval_nameserver_interval: tokio::time::Interval,

    udp_dns_server: l4_udp_dns_server::Server,
    tcp_dns_server: l4_tcp_dns_server::Server,

    tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,

    dns_queries: FuturesTupleSet<io::Result<dns_types::Response>, DnsQueryMetaData>,

    timeout: Option<Pin<Box<tokio::time::Sleep>>>,

    tun: Device,
    outbound_packet_buffer: VecDeque<IpPacket>,
    packet_counter: opentelemetry::metrics::Counter<u64>,
}

#[derive(Debug)]
struct DnsQueryMetaData {
    query: dns_types::Query,
    server: SocketAddr,
    transport: dns::Transport,
}

pub(crate) struct Buffers {
    ip: Vec<IpPacket>,
}

impl Default for Buffers {
    fn default() -> Self {
        Self {
            ip: Vec::with_capacity(MAX_INBOUND_PACKET_BATCH),
        }
    }
}

pub enum Input<D, I> {
    Timeout(Instant),
    Device(D),
    Network(I),
    TcpDnsQuery(l4_tcp_dns_server::Query),
    UdpDnsQuery(l4_udp_dns_server::Query),
    DnsResponse(dns::RecursiveResponse),
}

const DNS_QUERY_TIMEOUT: Duration = Duration::from_secs(5);
const RE_EVALUATE_NAMESERVER_INTERVAL: Duration = Duration::from_secs(60);

impl Io {
    /// Creates a new I/O abstraction
    ///
    /// Must be called within a Tokio runtime context so we can bind the sockets.
    pub fn new(
        tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
        udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
        nameservers: BTreeSet<IpAddr>,
    ) -> Self {
        let mut sockets = Sockets::default();
        sockets.rebind(udp_socket_factory.clone()); // Bind sockets on startup.

        Self {
            outbound_packet_buffer: VecDeque::default(),
            timeout: None,
            sockets,
            nameservers: NameserverSet::new(
                nameservers,
                tcp_socket_factory.clone(),
                udp_socket_factory.clone(),
            ),
            reval_nameserver_interval: tokio::time::interval(RE_EVALUATE_NAMESERVER_INTERVAL),
            tcp_socket_factory,
            udp_socket_factory,
            dns_queries: FuturesTupleSet::new(DNS_QUERY_TIMEOUT, 1000),
            gso_queue: GsoQueue::new(),
            tun: Device::new(),
            udp_dns_server: Default::default(),
            tcp_dns_server: Default::default(),
            packet_counter: opentelemetry::global::meter("connlib")
                .u64_counter("system.network.packets")
                .with_description("The number of packets processed.")
                .build(),
        }
    }

    pub fn rebind_dns_ipv4(&mut self, socket: SocketAddrV4) -> Result<()> {
        self.udp_dns_server.rebind_ipv4(socket)?;
        self.tcp_dns_server.rebind_ipv4(socket)?;

        Ok(())
    }

    pub fn rebind_dns_ipv6(&mut self, socket: SocketAddrV6) -> Result<()> {
        self.udp_dns_server.rebind_ipv6(socket)?;
        self.tcp_dns_server.rebind_ipv6(socket)?;

        Ok(())
    }

    pub fn poll_has_sockets(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        self.sockets.poll_has_sockets(cx)
    }

    pub fn fastest_nameserver(&self) -> Option<IpAddr> {
        self.nameservers.fastest()
    }

    pub fn poll<'b>(
        &mut self,
        cx: &mut Context<'_>,
        buffers: &'b mut Buffers,
    ) -> Poll<
        Result<
            Input<
                impl Iterator<Item = IpPacket> + use<'b>,
                impl for<'a> LendingIterator<Item<'a> = DatagramIn<'a>> + use<>,
            >,
        >,
    > {
        ready!(self.flush(cx)?);

        if self.reval_nameserver_interval.poll_tick(cx).is_ready() {
            self.nameservers.evaluate();
        }

        // We purposely don't want to block the event loop here because we can do plenty of other work while this is running.
        let _ = self.nameservers.poll(cx);

        if let Poll::Ready(network) = self.sockets.poll_recv_from(cx) {
            return Poll::Ready(Ok(Input::Network(
                network
                    .context("UDP socket failed")?
                    .filter(is_max_wg_packet_size),
            )));
        }

        if let Poll::Ready(num_packets) =
            self.tun
                .poll_read_many(cx, &mut buffers.ip, MAX_INBOUND_PACKET_BATCH)
        {
            let num_ipv4 = buffers.ip[..num_packets]
                .iter()
                .filter(|p| p.ipv4_header().is_some())
                .count();
            let num_ipv6 = num_packets - num_ipv4;

            self.packet_counter.add(
                num_ipv4 as u64,
                &[
                    otel::attr::network_type_ipv4(),
                    otel::attr::network_io_direction_receive(),
                ],
            );
            self.packet_counter.add(
                num_ipv6 as u64,
                &[
                    otel::attr::network_type_ipv6(),
                    otel::attr::network_io_direction_receive(),
                ],
            );

            return Poll::Ready(Ok(Input::Device(buffers.ip.drain(..num_packets))));
        }

        if let Poll::Ready(query) = self.udp_dns_server.poll(cx) {
            return Poll::Ready(Ok(Input::UdpDnsQuery(
                query.context("Failed to poll UDP DNS server")?,
            )));
        }

        if let Poll::Ready(query) = self.tcp_dns_server.poll(cx) {
            return Poll::Ready(Ok(Input::TcpDnsQuery(
                query.context("Failed to poll TCP DNS server")?,
            )));
        }

        match self.dns_queries.poll_unpin(cx) {
            Poll::Ready((result, meta)) => {
                let response = match result {
                    Ok(result) => dns::RecursiveResponse {
                        server: meta.server,
                        query: meta.query,
                        message: result,
                        transport: meta.transport,
                    },
                    Err(e @ futures_bounded::Timeout { .. }) => dns::RecursiveResponse {
                        server: meta.server,
                        query: meta.query,
                        message: Err(io::Error::new(io::ErrorKind::TimedOut, e)),
                        transport: meta.transport,
                    },
                };

                return Poll::Ready(Ok(Input::DnsResponse(response)));
            }
            Poll::Pending => {}
        }

        if let Some(timeout) = self.timeout.as_mut() {
            if timeout.poll_unpin(cx).is_ready() {
                // Always emit `now` as the timeout value.
                // This ensures that time within our state machine is always monotonic.
                // If we were to use the `deadline` of the timer instead, time may go backwards.
                // That is because it is valid to set a `Sleep` to a timestamp in the past.
                // It will resolve immediately but it will still report the old timestamp as its deadline.
                // To guard against this case, specifically call `Instant::now` here.
                let now = Instant::now();

                self.timeout = None; // Clear the timeout.

                return Poll::Ready(Ok(Input::Timeout(now)));
            }
        }

        Poll::Pending
    }

    fn flush(&mut self, cx: &mut Context<'_>) -> Poll<Result<()>> {
        let mut datagrams = self.gso_queue.datagrams();
        let mut any_pending = false;

        loop {
            if self.sockets.poll_send_ready(cx)?.is_pending() {
                any_pending = true;
                break;
            }

            let Some(datagram) = datagrams.next() else {
                break;
            };

            self.sockets.send(datagram)?;
        }

        loop {
            // First, check if we can send more packets.
            if self.tun.poll_send_ready(cx)?.is_pending() {
                any_pending = true;
                break;
            }

            // Second, check if we have any buffer packets.
            let Some(packet) = self.outbound_packet_buffer.pop_front() else {
                break; // No more packets? All done.
            };

            // Third, send the packet.
            self.tun
                .send(packet)
                .context("Failed to send IP packet to TUN device")?;
        }

        if any_pending {
            return Poll::Pending;
        }

        Poll::Ready(Ok(()))
    }

    pub fn set_tun(&mut self, tun: Box<dyn Tun>) {
        self.tun.set_tun(tun);
    }

    pub fn send_tun(&mut self, packet: IpPacket) {
        self.packet_counter.add(
            1,
            &[
                otel::attr::network_type_for_packet(&packet),
                otel::attr::network_io_direction_transmit(),
            ],
        );

        self.outbound_packet_buffer.push_back(packet);
    }

    pub fn reset(&mut self) {
        self.tcp_socket_factory.reset();
        self.udp_socket_factory.reset();
        self.sockets.rebind(self.udp_socket_factory.clone());
        self.gso_queue.clear();
        self.dns_queries = FuturesTupleSet::new(DNS_QUERY_TIMEOUT, 1000);
        self.nameservers.evaluate();
    }

    pub fn reset_timeout(&mut self, timeout: Instant, reason: &'static str) {
        let wakeup_in = tracing::event_enabled!(Level::TRACE)
            .then(|| timeout.duration_since(Instant::now()))
            .map(tracing::field::debug);
        let timeout = tokio::time::Instant::from_std(timeout);

        match self.timeout.as_mut() {
            Some(existing_timeout) if existing_timeout.deadline() != timeout => {
                tracing::trace!(wakeup_in, %reason);

                existing_timeout.as_mut().reset(timeout)
            }
            Some(_) => {}
            None => {
                self.timeout = {
                    tracing::trace!(?wakeup_in, %reason);

                    Some(Box::pin(tokio::time::sleep_until(timeout)))
                }
            }
        }
    }

    pub fn send_network(
        &mut self,
        src: Option<SocketAddr>,
        dst: SocketAddr,
        payload: &[u8],
        ecn: Ecn,
    ) {
        self.gso_queue.enqueue(src, dst, payload, ecn);

        self.packet_counter.add(
            1,
            &[
                otel::attr::network_protocol_name(payload),
                otel::attr::network_transport_udp(),
                otel::attr::network_io_direction_transmit(),
            ],
        );
    }

    pub fn send_dns_query(&mut self, query: dns::RecursiveQuery) {
        let meta = DnsQueryMetaData {
            query: query.message.clone(),
            server: query.server,
            transport: query.transport,
        };

        match query.transport {
            dns::Transport::Udp { .. } => {
                if self
                    .dns_queries
                    .try_push(
                        udp_dns::send(self.udp_socket_factory.clone(), query.server, query.message),
                        meta,
                    )
                    .is_err()
                {
                    tracing::debug!("Failed to queue UDP DNS query")
                }
            }
            dns::Transport::Tcp { .. } => {
                if self
                    .dns_queries
                    .try_push(
                        tcp_dns::send(self.tcp_socket_factory.clone(), query.server, query.message),
                        meta,
                    )
                    .is_err()
                {
                    tracing::debug!("Failed to queue TCP DNS query")
                }
            }
        }
    }

    pub(crate) fn send_udp_dns_response(
        &mut self,
        to: SocketAddr,
        message: dns_types::Response,
    ) -> io::Result<()> {
        self.udp_dns_server.send_response(to, message)
    }

    pub(crate) fn send_tcp_dns_response(
        &mut self,
        to: SocketAddr,
        message: dns_types::Response,
    ) -> io::Result<()> {
        self.tcp_dns_server.send_response(to, message)
    }
}

fn is_max_wg_packet_size(d: &DatagramIn) -> bool {
    let len = d.packet.len();
    if len > MAX_FZ_PAYLOAD {
        return false;
    }

    true
}

#[cfg(test)]
mod tests {
    use futures::task::noop_waker_ref;
    use std::{future::poll_fn, ptr::addr_of_mut};

    use super::*;

    #[tokio::test]
    async fn timer_is_reset_after_it_fires() {
        let mut io = Io::for_test();

        let deadline = Instant::now() + Duration::from_secs(1);
        io.reset_timeout(deadline, "");

        let Input::Timeout(timeout) = io.next().await else {
            panic!("Unexpected result");
        };

        assert!(timeout >= deadline, "timer expire after deadline");

        let poll = io.poll_test();

        assert!(poll.is_pending());
        assert!(io.timeout.is_none());
    }

    #[tokio::test]
    async fn emits_now_in_case_timeout_is_in_the_past() {
        let now = Instant::now();
        let mut io = Io::for_test();

        io.reset_timeout(now - Duration::from_secs(10), "");

        let Input::Timeout(timeout) = io.next().await else {
            panic!("Unexpected result");
        };

        assert!(timeout >= now, "timeout = {timeout:?}, now = {now:?}");
    }

    static mut DUMMY_BUF: Buffers = Buffers { ip: Vec::new() };

    /// Helper functions to make the test more concise.
    impl Io {
        fn for_test() -> Io {
            let mut io = Io::new(
                Arc::new(|_| Err(io::Error::other("not implemented"))),
                Arc::new(|_| Err(io::Error::other("not implemented"))),
                BTreeSet::new(),
            );
            io.set_tun(Box::new(DummyTun));

            io
        }

        async fn next(
            &mut self,
        ) -> Input<
            impl Iterator<Item = IpPacket> + use<>,
            impl for<'a> LendingIterator<Item<'a> = DatagramIn<'a>>,
        > {
            poll_fn(|cx| {
                self.poll(
                    cx,
                    // SAFETY: This is a test and we never receive packets here.
                    unsafe { &mut *addr_of_mut!(DUMMY_BUF) },
                )
            })
            .await
            .unwrap()
        }

        fn poll_test(
            &mut self,
        ) -> Poll<
            Result<
                Input<
                    impl Iterator<Item = IpPacket> + use<>,
                    impl for<'a> LendingIterator<Item<'a> = DatagramIn<'a>> + use<>,
                >,
            >,
        > {
            self.poll(
                &mut Context::from_waker(noop_waker_ref()),
                // SAFETY: This is a test and we never receive packets here.
                unsafe { &mut *addr_of_mut!(DUMMY_BUF) },
            )
        }
    }

    struct DummyTun;

    impl Tun for DummyTun {
        fn poll_send_ready(&mut self, _: &mut Context) -> Poll<io::Result<()>> {
            Poll::Ready(Ok(()))
        }

        fn send(&mut self, _: IpPacket) -> io::Result<()> {
            Ok(())
        }

        fn poll_recv_many(
            &mut self,
            _: &mut Context,
            _: &mut Vec<IpPacket>,
            _: usize,
        ) -> Poll<usize> {
            Poll::Pending
        }

        fn name(&self) -> &str {
            "dummy"
        }
    }
}
