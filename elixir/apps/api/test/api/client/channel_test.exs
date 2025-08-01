defmodule API.Client.ChannelTest do
  use API.ChannelCase, async: true
  alias Domain.Clients

  setup do
    account =
      Fixtures.Accounts.create_account(
        config: %{
          clients_upstream_dns: [
            %{protocol: "ip_port", address: "1.1.1.1"},
            %{protocol: "ip_port", address: "8.8.8.8:53"}
          ],
          search_domain: "example.com"
        },
        features: %{
          internet_resource: true
        }
      )

    actor_group = Fixtures.Actors.create_group(account: account)
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

    membership =
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

    identity = Fixtures.Auth.create_identity(actor: actor, account: account)
    subject = Fixtures.Auth.create_subject(identity: identity)
    client = Fixtures.Clients.create_client(subject: subject)

    gateway_group = Fixtures.Gateways.create_group(account: account)
    gateway_group_token = Fixtures.Gateways.create_token(account: account, group: gateway_group)
    gateway = Fixtures.Gateways.create_gateway(account: account, group: gateway_group)

    internet_gateway_group = Fixtures.Gateways.create_internet_group(account: account)

    internet_gateway_group_token =
      Fixtures.Gateways.create_token(account: account, group: internet_gateway_group)

    internet_gateway =
      Fixtures.Gateways.create_gateway(account: account, group: internet_gateway_group)

    dns_resource =
      Fixtures.Resources.create_resource(
        account: account,
        ip_stack: :ipv4_only,
        connections: [%{gateway_group_id: gateway_group.id}]
      )

    cidr_resource =
      Fixtures.Resources.create_resource(
        type: :cidr,
        address: "192.168.1.1/28",
        account: account,
        connections: [%{gateway_group_id: gateway_group.id}]
      )

    ip_resource =
      Fixtures.Resources.create_resource(
        type: :ip,
        address: "192.168.100.1",
        account: account,
        connections: [%{gateway_group_id: gateway_group.id}]
      )

    internet_resource =
      Fixtures.Resources.create_internet_resource(
        account: account,
        connections: [%{gateway_group_id: internet_gateway_group.id}]
      )

    unauthorized_resource =
      Fixtures.Resources.create_resource(
        account: account,
        connections: [%{gateway_group_id: gateway_group.id}]
      )

    nonconforming_resource =
      Fixtures.Resources.create_resource(
        account: account,
        connections: [%{gateway_group_id: gateway_group.id}]
      )

    offline_resource =
      Fixtures.Resources.create_resource(account: account)
      |> Ecto.Changeset.change(connections: [])
      |> Repo.update!()

    dns_resource_policy =
      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: dns_resource
      )

    Fixtures.Policies.create_policy(
      account: account,
      actor_group: actor_group,
      resource: cidr_resource
    )

    Fixtures.Policies.create_policy(
      account: account,
      actor_group: actor_group,
      resource: ip_resource
    )

    Fixtures.Policies.create_policy(
      account: account,
      actor_group: actor_group,
      resource: nonconforming_resource,
      conditions: [
        %{
          property: :remote_ip_location_region,
          operator: :is_not_in,
          values: [client.last_seen_remote_ip_location_region]
        }
      ]
    )

    internet_resource_policy =
      Fixtures.Policies.create_policy(
        account: account,
        actor_group: actor_group,
        resource: internet_resource
      )

    Fixtures.Policies.create_policy(
      account: account,
      actor_group: actor_group,
      resource: offline_resource
    )

    expires_at = DateTime.utc_now() |> DateTime.add(30, :second)

    subject = %{subject | expires_at: expires_at}

    {:ok, _reply, socket} =
      API.Client.Socket
      |> socket("client:#{client.id}", %{
        client: client,
        subject: subject
      })
      |> subscribe_and_join(API.Client.Channel, "client")

    %{
      account: account,
      actor: actor,
      actor_group: actor_group,
      identity: identity,
      subject: subject,
      client: client,
      gateway_group_token: gateway_group_token,
      gateway_group: gateway_group,
      membership: membership,
      gateway: gateway,
      internet_gateway_group: internet_gateway_group,
      internet_gateway_group_token: internet_gateway_group_token,
      internet_gateway: internet_gateway,
      dns_resource: dns_resource,
      cidr_resource: cidr_resource,
      ip_resource: ip_resource,
      internet_resource: internet_resource,
      unauthorized_resource: unauthorized_resource,
      nonconforming_resource: nonconforming_resource,
      offline_resource: offline_resource,
      dns_resource_policy: dns_resource_policy,
      internet_resource_policy: internet_resource_policy,
      socket: socket
    }
  end

  describe "join/3" do
    test "tracks presence after join", %{account: account, client: client} do
      presence = Clients.Presence.Account.list(account.id)

      assert %{metas: [%{online_at: online_at, phx_ref: _ref}]} = Map.fetch!(presence, client.id)
      assert is_number(online_at)
    end

    test "does not crash when subject expiration is too large", %{
      client: client,
      subject: subject
    } do
      expires_at = DateTime.utc_now() |> DateTime.add(100_000_000_000, :millisecond)
      subject = %{subject | expires_at: expires_at}

      # We need to trap exits to avoid test process termination
      # because it is linked to the created test channel process
      Process.flag(:trap_exit, true)

      {:ok, _reply, _socket} =
        API.Client.Socket
        |> socket("client:#{client.id}", %{
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      refute_receive {:EXIT, _pid, _}
      refute_receive {:socket_close, _pid, _}
    end

    test "send disconnect broadcast when the token is deleted", %{
      client: client,
      subject: subject
    } do
      # We need to trap exits to avoid test process termination
      # because it is linked to the created test channel process
      Process.flag(:trap_exit, true)

      :ok = Domain.PubSub.subscribe("sessions:#{subject.token_id}")

      {:ok, _reply, _socket} =
        API.Client.Socket
        |> socket("client:#{client.id}", %{
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      token = Repo.get_by(Domain.Tokens.Token, id: subject.token_id)

      data = %{
        "id" => token.id,
        "account_id" => token.account_id,
        "type" => token.type,
        "expires_at" => token.expires_at
      }

      Domain.Events.Hooks.Tokens.on_delete(data)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: topic,
        event: "disconnect"
      }

      assert topic == "sessions:#{token.id}"
    end

    test "selects compatible gateway versions", %{client: client, subject: subject} do
      client = %{client | last_seen_version: "1.0.99"}

      {:ok, _reply, socket} =
        API.Client.Socket
        |> socket("client:#{client.id}", %{
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      assert socket.assigns.gateway_version_requirement == "> 0.0.0"

      client = %{client | last_seen_version: "1.1.99"}

      {:ok, _reply, socket} =
        API.Client.Socket
        |> socket("client:#{client.id}", %{
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      assert socket.assigns.gateway_version_requirement == ">= 1.1.0"

      client = %{client | last_seen_version: "development"}

      assert API.Client.Socket
             |> socket("client:#{client.id}", %{
               client: client,
               subject: subject
             })
             |> subscribe_and_join(API.Client.Channel, "client") ==
               {:error, %{reason: :invalid_version}}
    end

    test "sends list of available resources after join", %{
      client: client,
      internet_gateway_group: internet_gateway_group,
      gateway_group: gateway_group,
      dns_resource: dns_resource,
      cidr_resource: cidr_resource,
      ip_resource: ip_resource,
      nonconforming_resource: nonconforming_resource,
      internet_resource: internet_resource,
      offline_resource: offline_resource
    } do
      assert_push "init", %{
        resources: resources,
        interface: interface,
        relays: relays
      }

      assert length(resources) == 4
      assert length(relays) == 0

      assert %{
               id: dns_resource.id,
               type: :dns,
               ip_stack: :ipv4_only,
               name: dns_resource.name,
               address: dns_resource.address,
               address_description: dns_resource.address_description,
               gateway_groups: [
                 %{
                   id: gateway_group.id,
                   name: gateway_group.name
                 }
               ],
               filters: [
                 %{protocol: :tcp, port_range_end: 80, port_range_start: 80},
                 %{protocol: :tcp, port_range_end: 433, port_range_start: 433},
                 %{protocol: :udp, port_range_end: 200, port_range_start: 100},
                 %{protocol: :icmp}
               ]
             } in resources

      assert %{
               id: cidr_resource.id,
               type: :cidr,
               name: cidr_resource.name,
               address: cidr_resource.address,
               address_description: cidr_resource.address_description,
               gateway_groups: [
                 %{
                   id: gateway_group.id,
                   name: gateway_group.name
                 }
               ],
               filters: [
                 %{protocol: :tcp, port_range_end: 80, port_range_start: 80},
                 %{protocol: :tcp, port_range_end: 433, port_range_start: 433},
                 %{protocol: :udp, port_range_end: 200, port_range_start: 100},
                 %{protocol: :icmp}
               ]
             } in resources

      assert %{
               id: ip_resource.id,
               type: :cidr,
               name: ip_resource.name,
               address: "#{ip_resource.address}/32",
               address_description: ip_resource.address_description,
               gateway_groups: [
                 %{
                   id: gateway_group.id,
                   name: gateway_group.name
                 }
               ],
               filters: [
                 %{protocol: :tcp, port_range_end: 80, port_range_start: 80},
                 %{protocol: :tcp, port_range_end: 433, port_range_start: 433},
                 %{protocol: :udp, port_range_end: 200, port_range_start: 100},
                 %{protocol: :icmp}
               ]
             } in resources

      assert %{
               id: internet_resource.id,
               type: :internet,
               gateway_groups: [
                 %{
                   id: internet_gateway_group.id,
                   name: internet_gateway_group.name
                 }
               ],
               can_be_disabled: true
             } in resources

      refute Enum.any?(resources, &(&1.id == nonconforming_resource.id))
      refute Enum.any?(resources, &(&1.id == offline_resource.id))

      assert interface == %{
               ipv4: client.ipv4,
               ipv6: client.ipv6,
               upstream_dns: [
                 %{protocol: :ip_port, address: "1.1.1.1:53"},
                 %{protocol: :ip_port, address: "8.8.8.8:53"}
               ],
               search_domain: "example.com"
             }
    end

    test "only sends the same resource once", %{
      account: account,
      actor: actor,
      subject: subject,
      client: client,
      dns_resource: resource
    } do
      assert_push "init", %{}

      Fixtures.Auth.create_identity(actor: actor, account: account)
      Fixtures.Auth.create_identity(actor: actor, account: account)

      second_actor_group = Fixtures.Actors.create_group(account: account)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: second_actor_group)

      Fixtures.Policies.create_policy(
        account: account,
        actor_group: second_actor_group,
        resource: resource
      )

      API.Client.Socket
      |> socket("client:#{client.id}", %{
        client: client,
        subject: subject
      })
      |> subscribe_and_join(API.Client.Channel, "client")

      assert_push "init", %{resources: resources}
      assert Enum.count(resources, &(Map.get(&1, :address) == resource.address)) == 1
    end

    test "sends backwards compatible list of resources if client version is below 1.2", %{
      account: account,
      subject: subject,
      client: client,
      gateway_group: gateway_group,
      actor_group: actor_group
    } do
      client = %{client | last_seen_version: "1.1.55"}

      assert_push "init", %{}

      star_mapped_resource =
        Fixtures.Resources.create_resource(
          address: "**.glob-example.com",
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      question_mark_mapped_resource =
        Fixtures.Resources.create_resource(
          address: "*.question-example.com",
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      mid_question_mark_mapped_resource =
        Fixtures.Resources.create_resource(
          address: "foo.*.example.com",
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      mid_star_mapped_resource =
        Fixtures.Resources.create_resource(
          address: "foo.**.glob-example.com",
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      mid_single_char_mapped_resource =
        Fixtures.Resources.create_resource(
          address: "us-east?-d.glob-example.com",
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      for resource <- [
            star_mapped_resource,
            question_mark_mapped_resource,
            mid_question_mark_mapped_resource,
            mid_star_mapped_resource,
            mid_single_char_mapped_resource
          ] do
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group,
          resource: resource
        )
      end

      API.Client.Socket
      |> socket("client:#{client.id}", %{
        client: client,
        subject: subject
      })
      |> subscribe_and_join(API.Client.Channel, "client")

      assert_push "init", %{
        resources: resources
      }

      resource_addresses =
        resources
        |> Enum.reject(&(&1.type == :internet))
        |> Enum.map(& &1.address)

      assert "*.glob-example.com" in resource_addresses
      assert "?.question-example.com" in resource_addresses

      assert "foo.*.example.com" not in resource_addresses
      assert "foo.?.example.com" not in resource_addresses

      assert "foo.**.glob-example.com" not in resource_addresses
      assert "foo.*.glob-example.com" not in resource_addresses

      assert "us-east?-d.glob-example.com" not in resource_addresses
      assert "us-east*-d.glob-example.com" not in resource_addresses
    end

    test "subscribes for relays presence", %{client: client, subject: subject} do
      relay_group = Fixtures.Relays.create_global_group()

      relay1 = Fixtures.Relays.create_relay(group: relay_group)
      stamp_secret1 = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(relay1, stamp_secret1)

      Fixtures.Relays.update_relay(relay1,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second),
        last_seen_remote_ip_location_lat: 37.0,
        last_seen_remote_ip_location_lon: -120.0
      )

      relay2 = Fixtures.Relays.create_relay(group: relay_group)
      stamp_secret2 = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(relay2, stamp_secret2)

      Fixtures.Relays.update_relay(relay2,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-100, :second),
        last_seen_remote_ip_location_lat: 38.0,
        last_seen_remote_ip_location_lon: -121.0
      )

      API.Client.Socket
      |> socket("client:#{client.id}", %{
        client: client,
        subject: subject
      })
      |> subscribe_and_join(API.Client.Channel, "client")

      assert_push "init", %{relays: [relay_view | _] = relays}
      relay_view_ids = Enum.map(relays, & &1.id) |> Enum.uniq() |> Enum.sort()
      relay_ids = [relay1.id, relay2.id] |> Enum.sort()
      assert relay_view_ids == relay_ids

      assert %{
               addr: _,
               expires_at: _,
               id: _,
               password: _,
               type: _,
               username: _
             } = relay_view

      Domain.Relays.Presence.untrack(self(), "presences:relays:#{relay1.id}", relay1.id)

      assert_push "relays_presence",
                  %{
                    disconnected_ids: [relay1_id],
                    connected: [relay_view1, relay_view2]
                  },
                  relays_presence_timeout()

      assert relay_view1.id == relay2.id
      assert relay_view2.id == relay2.id
      assert relay1_id == relay1.id
    end

    test "subscribes for account relays presence if there were no relays online", %{
      client: client,
      subject: subject
    } do
      relay_group = Fixtures.Relays.create_global_group()
      stamp_secret = Ecto.UUID.generate()

      relay = Fixtures.Relays.create_relay(group: relay_group)

      Fixtures.Relays.update_relay(relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second),
        last_seen_remote_ip_location_lat: 37.0,
        last_seen_remote_ip_location_lon: -120.0
      )

      API.Client.Socket
      |> socket("client:#{client.id}", %{
        client: client,
        subject: subject
      })
      |> subscribe_and_join(API.Client.Channel, "client")

      assert_push "init", %{relays: []}

      :ok = Domain.Relays.connect_relay(relay, stamp_secret)

      assert_push "relays_presence",
                  %{
                    disconnected_ids: [],
                    connected: [relay_view, _relay_view]
                  },
                  relays_presence_timeout()

      assert %{
               addr: _,
               expires_at: _,
               id: _,
               password: _,
               type: _,
               username: _
             } = relay_view

      other_relay = Fixtures.Relays.create_relay(group: relay_group)

      Fixtures.Relays.update_relay(other_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second),
        last_seen_remote_ip_location_lat: 37.0,
        last_seen_remote_ip_location_lon: -120.0
      )

      :ok = Domain.Relays.connect_relay(other_relay, stamp_secret)
      other_relay_id = other_relay.id

      refute_push "relays_presence",
                  %{
                    disconnected_ids: [],
                    connected: [%{id: ^other_relay_id} | _]
                  },
                  relays_presence_timeout()
    end

    test "does not return the relay that is disconnected as online one", %{
      client: client,
      subject: subject
    } do
      relay_group = Fixtures.Relays.create_global_group()
      stamp_secret = Ecto.UUID.generate()

      relay1 = Fixtures.Relays.create_relay(group: relay_group)
      :ok = Domain.Relays.connect_relay(relay1, stamp_secret)

      Fixtures.Relays.update_relay(relay1,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second),
        last_seen_remote_ip_location_lat: 37.0,
        last_seen_remote_ip_location_lon: -120.0
      )

      API.Client.Socket
      |> socket("client:#{client.id}", %{
        client: client,
        subject: subject
      })
      |> subscribe_and_join(API.Client.Channel, "client")

      assert_push "init", %{relays: [relay_view | _] = relays}
      relay_view_ids = Enum.map(relays, & &1.id) |> Enum.uniq() |> Enum.sort()
      assert relay_view_ids == [relay1.id]

      assert %{
               addr: _,
               expires_at: _,
               id: _,
               password: _,
               type: _,
               username: _
             } = relay_view

      Domain.Relays.Presence.untrack(self(), "presences:relays:#{relay1.id}", relay1.id)

      assert_push "relays_presence",
                  %{
                    disconnected_ids: [relay1_id],
                    connected: []
                  },
                  relays_presence_timeout()

      assert relay1_id == relay1.id
    end
  end

  describe "handle_info/2" do
    # test "subscribes for client events", %{
    #   client: client
    # } do
    #   assert_push "init", %{}
    #   Process.flag(:trap_exit, true)
    #   PubSub.Client.broadcast(client.id, :token_expired)
    #   assert_push "disconnect", %{reason: :token_expired}, 250
    # end

    # test "subscribes for resource events", %{
    #   dns_resource: resource,
    #   subject: subject
    # } do
    #   assert_push "init", %{}
    #
    #   {:ok, _resource} = Domain.Resources.update_resource(resource, %{name: "foobar"}, subject)
    #
    #   old_data = %{
    #     "id" => resource.id,
    #     "account_id" => resource.account_id,
    #     "address" => resource.address,
    #     "name" => resource.name,
    #     "type" => "dns",
    #     "filters" => [],
    #     "ip_stack" => "dual"
    #   }
    #
    #   data = Map.put(old_data, "name", "new name")
    #   Events.Hooks.Resources.on_update(old_data, data)
    #
    #   assert_push "resource_created_or_updated", %{}
    # end

    # test "subscribes for policy events", %{
    #   dns_resource_policy: dns_resource_policy,
    #   subject: subject
    # } do
    #   assert_push "init", %{}
    #   {:ok, policy} = Domain.Policies.disable_policy(dns_resource_policy, subject)
    #
    #   # Simulate disable
    #   old_data = %{
    #     "id" => policy.id,
    #     "account_id" => policy.account_id,
    #     "resource_id" => policy.resource_id,
    #     "actor_group_id" => policy.actor_group_id,
    #     "conditions" => [],
    #     "disabled_at" => nil
    #   }
    #
    #   data = Map.put(old_data, "disabled_at", "2024-01-01T00:00:00Z")
    #   Events.Hooks.Policies.on_update(old_data, data)
    #
    #   assert_push "resource_deleted", _payload
    #   refute_push "resource_created_or_updated", _payload
    # end

    # describe "handle_info/2 :config_changed" do
    #   test "sends updated configuration", %{
    #     account: account,
    #     client: client,
    #     socket: socket
    #   } do
    #     channel_pid = socket.channel_pid
    #
    #     Fixtures.Accounts.update_account(
    #       account,
    #       config: %{
    #         clients_upstream_dns: [
    #           %{protocol: "ip_port", address: "1.2.3.1"},
    #           %{protocol: "ip_port", address: "1.8.8.1:53"}
    #         ],
    #         search_domain: "example.com"
    #       }
    #     )
    #
    #     send(channel_pid, :config_changed)
    #
    #     assert_push "config_changed", %{interface: interface}
    #
    #     assert interface == %{
    #              ipv4: client.ipv4,
    #              ipv6: client.ipv6,
    #              upstream_dns: [
    #                %{protocol: :ip_port, address: "1.2.3.1:53"},
    #                %{protocol: :ip_port, address: "1.8.8.1:53"}
    #              ],
    #              search_domain: "example.com"
    #            }
    #   end
    # end

    # describe "handle_info/2 {:updated, client}" do
    #   test "sends init message when breaking fields change", %{
    #     socket: socket,
    #     client: client
    #   } do
    #     assert_push "init", %{}
    #
    #     updated_client = %{client | verified_at: DateTime.utc_now()}
    #     send(socket.channel_pid, {:updated, updated_client})
    #     assert_push "init", %{}
    #   end
    #
    #   test "does not send init message when name changes", %{
    #     socket: socket,
    #     client: client
    #   } do
    #     assert_push "init", %{}
    #
    #     send(socket.channel_pid, {:updated, %{client | name: "New Name"}})
    #
    #     refute_push "init", %{}
    #   end
    # end

    # describe "handle_info/2 :token_expired" do
    #   test "sends a token_expired messages and closes the socket", %{
    #     socket: socket
    #   } do
    #     Process.flag(:trap_exit, true)
    #     channel_pid = socket.channel_pid
    #
    #     send(channel_pid, :token_expired)
    #     assert_push "disconnect", %{reason: :token_expired}
    #
    #     assert_receive {:EXIT, ^channel_pid, {:shutdown, :token_expired}}
    #   end
    # end

    test "pushes ice_candidates message", %{
      client: client,
      gateway: gateway,
      socket: socket
    } do
      candidates = ["foo", "bar"]

      send(
        socket.channel_pid,
        {{:ice_candidates, client.id}, gateway.id, candidates}
      )

      assert_push "ice_candidates", payload

      assert payload == %{
               candidates: candidates,
               gateway_id: gateway.id
             }
    end

    test "pushes invalidate_ice_candidates message", %{
      client: client,
      gateway: gateway,
      socket: socket
    } do
      candidates = ["foo", "bar"]

      send(
        socket.channel_pid,
        {{:invalidate_ice_candidates, client.id}, gateway.id, candidates}
      )

      assert_push "invalidate_ice_candidates", payload

      assert payload == %{
               candidates: candidates,
               gateway_id: gateway.id
             }
    end

    #   test "pushes message to the socket for authorized clients", %{
    #     gateway_group: gateway_group,
    #     dns_resource: resource,
    #     socket: socket
    #   } do
    #     send(socket.channel_pid, {:create_resource, resource.id})
    #
    #     assert_push "resource_created_or_updated", payload
    #
    #     assert payload == %{
    #              id: resource.id,
    #              type: :dns,
    #              ip_stack: :ipv4_only,
    #              name: resource.name,
    #              address: resource.address,
    #              address_description: resource.address_description,
    #              gateway_groups: [
    #                %{id: gateway_group.id, name: gateway_group.name}
    #              ],
    #              filters: [
    #                %{protocol: :tcp, port_range_end: 80, port_range_start: 80},
    #                %{protocol: :tcp, port_range_end: 433, port_range_start: 433},
    #                %{protocol: :udp, port_range_end: 200, port_range_start: 100},
    #                %{protocol: :icmp}
    #              ]
    #            }
    #   end
    #
    #   test "does not push resources that can't be access by the client", %{
    #     nonconforming_resource: resource,
    #     socket: socket
    #   } do
    #     send(socket.channel_pid, {:create_resource, resource.id})
    #     refute_push "resource_created_or_updated", %{}
    #   end
    # end

    #   test "pushes message to the socket for authorized clients", %{
    #     gateway_group: gateway_group,
    #     dns_resource: resource,
    #     socket: socket
    #   } do
    #     send(socket.channel_pid, {:update_resource, resource.id})
    #
    #     assert_push "resource_created_or_updated", payload
    #
    #     assert payload == %{
    #              id: resource.id,
    #              type: :dns,
    #              ip_stack: :ipv4_only,
    #              name: resource.name,
    #              address: resource.address,
    #              address_description: resource.address_description,
    #              gateway_groups: [
    #                %{id: gateway_group.id, name: gateway_group.name}
    #              ],
    #              filters: [
    #                %{protocol: :tcp, port_range_end: 80, port_range_start: 80},
    #                %{protocol: :tcp, port_range_end: 433, port_range_start: 433},
    #                %{protocol: :udp, port_range_end: 200, port_range_start: 100},
    #                %{protocol: :icmp}
    #              ]
    #            }
    #   end
    #
    #   test "does not push resources that can't be access by the client", %{
    #     nonconforming_resource: resource,
    #     socket: socket
    #   } do
    #     send(socket.channel_pid, {:update_resource, resource.id})
    #     refute_push "resource_created_or_updated", %{}
    #   end

    #   test "does nothing", %{
    #     dns_resource: resource,
    #     socket: socket
    #   } do
    #     send(socket.channel_pid, {:delete_resource, resource.id})
    #     refute_push "resource_deleted", %{}
    #   end

    #   test "subscribes for policy events for actor group", %{
    #     account: account,
    #     gateway_group: gateway_group,
    #     actor: actor,
    #     socket: socket
    #   } do
    #     resource =
    #       Fixtures.Resources.create_resource(
    #         type: :ip,
    #         address: "192.168.100.2",
    #         account: account,
    #         connections: [%{gateway_group_id: gateway_group.id}]
    #       )
    #
    #     group = Fixtures.Actors.create_group(account: account)
    #
    #     policy =
    #       Fixtures.Policies.create_policy(
    #         account: account,
    #         actor_group: group,
    #         resource: resource
    #       )
    #
    #     send(socket.channel_pid, {:create_membership, actor.id, group.id})
    #
    #     Fixtures.Policies.disable_policy(policy)
    #
    #     # Simulate disable
    #     old_data = %{
    #       "id" => policy.id,
    #       "account_id" => policy.account_id,
    #       "resource_id" => policy.resource_id,
    #       "actor_group_id" => policy.actor_group_id,
    #       "conditions" => [],
    #       "disabled_at" => nil
    #     }
    #
    #     data = Map.put(old_data, "disabled_at", "2024-01-01T00:00:00Z")
    #     Events.Hooks.Policies.on_update(old_data, data)
    #
    #     assert_push "resource_deleted", resource_id
    #     assert resource_id == resource.id
    #
    #     refute_push "resource_created_or_updated", %{}
    #   end
    # end

    # test "allow_access pushes message to the socket", %{
    #   account: account,
    #   gateway: gateway,
    #   gateway_group: gateway_group,
    #   dns_resource: resource,
    #   socket: socket
    # } do
    #   group = Fixtures.Actors.create_group(account: account)
    #
    #   policy =
    #     Fixtures.Policies.create_policy(
    #       account: account,
    #       actor_group: group,
    #       resource: resource
    #     )
    #
    #   send(socket.channel_pid, {:allow_access, policy.id, group.id, resource.id})
    #
    #   assert_push "resource_created_or_updated", payload
    #
    #   assert payload == %{
    #            id: resource.id,
    #            type: :dns,
    #            ip_stack: :ipv4_only,
    #            name: resource.name,
    #            address: resource.address,
    #            address_description: resource.address_description,
    #            gateway_groups: [
    #              %{id: gateway_group.id, name: gateway_group.name}
    #            ],
    #            filters: [
    #              %{protocol: :tcp, port_range_end: 80, port_range_start: 80},
    #              %{protocol: :tcp, port_range_end: 433, port_range_start: 433},
    #              %{protocol: :udp, port_range_end: 200, port_range_start: 100},
    #              %{protocol: :icmp}
    #            ]
    #          }
    # end

    #   test "pushes message to the socket", %{
    #     account: account,
    #     gateway_group: gateway_group,
    #     socket: socket
    #   } do
    #     resource =
    #       Fixtures.Resources.create_resource(
    #         type: :ip,
    #         address: "192.168.100.3",
    #         account: account,
    #         connections: [%{gateway_group_id: gateway_group.id}]
    #       )
    #
    #     group = Fixtures.Actors.create_group(account: account)
    #
    #     policy =
    #       Fixtures.Policies.create_policy(
    #         account: account,
    #         actor_group: group,
    #         resource: resource
    #       )
    #
    #     send(socket.channel_pid, {:reject_access, policy.id, group.id, resource.id})
    #
    #     assert_push "resource_deleted", resource_id
    #     assert resource_id == resource.id
    #
    #     refute_push "resource_created_or_updated", %{}
    #   end
    #
    #   test "broadcasts a message to re-add the resource if other policy is found", %{
    #     account: account,
    #     gateway_group: gateway_group,
    #     dns_resource: resource,
    #     socket: socket
    #   } do
    #     group = Fixtures.Actors.create_group(account: account)
    #
    #     policy =
    #       Fixtures.Policies.create_policy(
    #         account: account,
    #         actor_group: group,
    #         resource: resource
    #       )
    #
    #     send(socket.channel_pid, {:reject_access, policy.id, group.id, resource.id})
    #
    #     assert_push "resource_deleted", resource_id
    #     assert resource_id == resource.id
    #
    #     assert_push "resource_created_or_updated", payload
    #
    #     assert payload == %{
    #              id: resource.id,
    #              type: :dns,
    #              ip_stack: :ipv4_only,
    #              name: resource.name,
    #              address: resource.address,
    #              address_description: resource.address_description,
    #              gateway_groups: [
    #                %{id: gateway_group.id, name: gateway_group.name}
    #              ],
    #              filters: [
    #                %{protocol: :tcp, port_range_end: 80, port_range_start: 80},
    #                %{protocol: :tcp, port_range_end: 433, port_range_start: 433},
    #                %{protocol: :udp, port_range_end: 200, port_range_start: 100},
    #                %{protocol: :icmp}
    #              ]
    #            }
    #   end
    # end
  end

  describe "handle_in/3 create_flow" do
    test "returns error when resource is not found", %{socket: socket} do
      resource_id = Ecto.UUID.generate()

      push(socket, "create_flow", %{
        "resource_id" => resource_id,
        "connected_gateway_ids" => []
      })

      assert_push "flow_creation_failed", %{reason: :not_found, resource_id: ^resource_id}
    end

    test "returns error when all gateways are offline", %{
      dns_resource: resource,
      socket: socket
    } do
      global_relay_group = Fixtures.Relays.create_global_group()

      global_relay =
        Fixtures.Relays.create_relay(
          group: global_relay_group,
          last_seen_remote_ip_location_lat: 37,
          last_seen_remote_ip_location_lon: -120
        )

      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(global_relay, stamp_secret)

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      assert_push "flow_creation_failed", %{reason: :offline, resource_id: resource_id}
      assert resource_id == resource.id
    end

    test "returns error when client has no policy allowing access to resource", %{
      account: account,
      socket: socket
    } do
      resource = Fixtures.Resources.create_resource(account: account)

      gateway = Fixtures.Gateways.create_gateway(account: account)
      :ok = Domain.Gateways.Presence.connect(gateway)

      attrs = %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      }

      push(socket, "create_flow", attrs)

      assert_push "flow_creation_failed", %{reason: :not_found, resource_id: resource_id}
      assert resource_id == resource.id
    end

    test "returns error when flow is not authorized due to failing conditions", %{
      account: account,
      client: client,
      actor_group: actor_group,
      gateway_group: gateway_group,
      gateway: gateway,
      membership: membership,
      socket: socket
    } do
      send(socket.channel_pid, {:created, membership})

      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      send(socket.channel_pid, {:created, resource})

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group,
          resource: resource,
          conditions: [
            %{
              property: :remote_ip_location_region,
              operator: :is_not_in,
              values: [client.last_seen_remote_ip_location_region]
            }
          ]
        )

      send(socket.channel_pid, {:created, policy})

      attrs = %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      }

      :ok = Domain.Gateways.Presence.connect(gateway)

      push(socket, "create_flow", attrs)

      assert_push "flow_creation_failed", %{
        reason: :forbidden,
        violated_properties: [:remote_ip_location_region],
        resource_id: resource_id
      }

      assert resource_id == resource.id
    end

    test "returns error when all gateways connected to the resource are offline", %{
      account: account,
      dns_resource: resource,
      socket: socket
    } do
      gateway = Fixtures.Gateways.create_gateway(account: account)
      :ok = Domain.Gateways.Presence.connect(gateway)

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      assert_push "flow_creation_failed", %{
        reason: :offline,
        resource_id: resource_id
      }

      assert resource_id == resource.id
    end

    test "returns online gateway connected to a resource", %{
      dns_resource: resource,
      dns_resource_policy: policy,
      membership: membership,
      client: client,
      gateway_group_token: gateway_group_token,
      gateway: gateway,
      socket: socket
    } do
      global_relay_group = Fixtures.Relays.create_global_group()

      global_relay =
        Fixtures.Relays.create_relay(
          group: global_relay_group,
          last_seen_remote_ip_location_lat: 37,
          last_seen_remote_ip_location_lon: -120
        )

      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(global_relay, stamp_secret)

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      :ok = Domain.PubSub.Account.subscribe(gateway.account_id)
      :ok = Domain.Gateways.Presence.connect(gateway)
      Domain.PubSub.subscribe(Domain.Tokens.socket_id(gateway_group_token))

      # Prime cache
      send(socket.channel_pid, {:created, resource})
      send(socket.channel_pid, {:created, policy})
      send(socket.channel_pid, {:created, membership})

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      gateway_id = gateway.id

      assert_receive {{:authorize_flow, ^gateway_id}, {_channel_pid, _socket_ref}, payload}

      assert %{
               client: received_client,
               resource: received_resource,
               authorization_expires_at: authorization_expires_at,
               ice_credentials: _ice_credentials,
               preshared_key: preshared_key
             } = payload

      assert received_client.id == client.id
      assert received_resource.id == resource.id
      assert authorization_expires_at == socket.assigns.subject.expires_at
      assert String.length(preshared_key) == 44
    end

    test "returns online gateway connected to an internet resource", %{
      account: account,
      membership: membership,
      internet_resource_policy: policy,
      internet_gateway_group_token: gateway_group_token,
      internet_gateway: gateway,
      internet_resource: resource,
      client: client,
      socket: socket
    } do
      Fixtures.Accounts.update_account(account,
        features: %{
          internet_resource: true
        }
      )

      global_relay_group = Fixtures.Relays.create_global_group()

      global_relay =
        Fixtures.Relays.create_relay(
          group: global_relay_group,
          last_seen_remote_ip_location_lat: 37,
          last_seen_remote_ip_location_lon: -120
        )

      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(global_relay, stamp_secret)

      :ok = Domain.PubSub.Account.subscribe(account.id)

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      :ok = Domain.Gateways.Presence.connect(gateway)
      Domain.PubSub.subscribe(Domain.Tokens.socket_id(gateway_group_token))

      send(socket.channel_pid, {:created, resource})
      send(socket.channel_pid, {:created, policy})
      send(socket.channel_pid, {:created, membership})

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      gateway_id = gateway.id

      assert_receive {{:authorize_flow, ^gateway_id}, {_channel_pid, _socket_ref}, payload}

      assert %{
               client: recv_client,
               resource: recv_resource,
               authorization_expires_at: authorization_expires_at,
               ice_credentials: _ice_credentials,
               preshared_key: preshared_key
             } = payload

      assert recv_client.id == client.id
      assert recv_resource.id == resource.id
      assert authorization_expires_at == socket.assigns.subject.expires_at
      assert String.length(preshared_key) == 44
    end

    test "broadcasts authorize_flow to the gateway and flow_created to the client", %{
      dns_resource: resource,
      dns_resource_policy: policy,
      membership: membership,
      client: client,
      gateway_group_token: gateway_group_token,
      gateway: gateway,
      subject: subject,
      socket: socket
    } do
      global_relay_group = Fixtures.Relays.create_global_group()

      global_relay =
        Fixtures.Relays.create_relay(
          group: global_relay_group,
          last_seen_remote_ip_location_lat: 37,
          last_seen_remote_ip_location_lon: -120
        )

      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(global_relay, stamp_secret)
      :ok = Domain.PubSub.Account.subscribe(gateway.account_id)

      send(socket.channel_pid, {:created, resource})
      send(socket.channel_pid, {:created, policy})
      send(socket.channel_pid, {:created, membership})

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      :ok = Domain.Gateways.Presence.connect(gateway)
      Domain.PubSub.subscribe(Domain.Tokens.socket_id(gateway_group_token))

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      gateway_id = gateway.id

      assert_receive {{:authorize_flow, ^gateway_id}, {channel_pid, socket_ref}, payload}

      assert %{
               client: recv_client,
               resource: recv_resource,
               authorization_expires_at: authorization_expires_at,
               ice_credentials: ice_credentials,
               preshared_key: preshared_key
             } = payload

      client_id = recv_client.id
      resource_id = recv_resource.id

      assert flow = Repo.get_by(Domain.Flows.Flow, client_id: client.id, resource_id: resource.id)
      assert flow.client_id == client_id
      assert flow.resource_id == resource_id
      assert flow.gateway_id == gateway.id
      assert flow.policy_id == policy.id
      assert flow.token_id == subject.token_id

      assert client_id == client.id
      assert resource_id == resource.id
      assert authorization_expires_at == socket.assigns.subject.expires_at

      send(
        channel_pid,
        {:connect, socket_ref, resource_id, gateway.group_id, gateway.id, gateway.public_key,
         gateway.ipv4, gateway.ipv6, preshared_key, ice_credentials}
      )

      gateway_group_id = gateway.group_id
      gateway_id = gateway.id
      gateway_public_key = gateway.public_key
      gateway_ipv4 = gateway.ipv4
      gateway_ipv6 = gateway.ipv6

      assert_push "flow_created", %{
        gateway_public_key: ^gateway_public_key,
        gateway_ipv4: ^gateway_ipv4,
        gateway_ipv6: ^gateway_ipv6,
        resource_id: ^resource_id,
        client_ice_credentials: %{username: client_ice_username, password: client_ice_password},
        gateway_group_id: ^gateway_group_id,
        gateway_id: ^gateway_id,
        gateway_ice_credentials: %{
          username: gateway_ice_username,
          password: gateway_ice_password
        },
        preshared_key: ^preshared_key
      }

      assert String.length(client_ice_username) == 4
      assert String.length(client_ice_password) == 22
      assert String.length(gateway_ice_username) == 4
      assert String.length(gateway_ice_password) == 22
      assert client_ice_username != gateway_ice_username
      assert client_ice_password != gateway_ice_password
    end

    test "works with service accounts", %{
      account: account,
      dns_resource: resource,
      dns_resource_policy: policy,
      membership: membership,
      gateway: gateway,
      gateway_group_token: gateway_group_token,
      actor_group: actor_group
    } do
      actor = Fixtures.Actors.create_actor(type: :service_account, account: account)
      client = Fixtures.Clients.create_client(account: account, actor: actor)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

      {:ok, _reply, socket} =
        API.Client.Socket
        |> socket("client:#{client.id}", %{
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      global_relay_group = Fixtures.Relays.create_global_group()

      global_relay =
        Fixtures.Relays.create_relay(
          group: global_relay_group,
          last_seen_remote_ip_location_lat: 37,
          last_seen_remote_ip_location_lon: -120
        )

      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(global_relay, stamp_secret)

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      :ok = Domain.Gateways.Presence.connect(gateway)
      Domain.PubSub.subscribe(Domain.Tokens.socket_id(gateway_group_token))

      :ok = Domain.PubSub.Account.subscribe(account.id)

      send(socket.channel_pid, {:created, resource})
      send(socket.channel_pid, {:created, policy})
      send(socket.channel_pid, {:created, membership})

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      gateway_id = gateway.id

      assert_receive {{:authorize_flow, ^gateway_id}, {_channel_pid, _socket_ref}, _payload}
    end

    test "selects compatible gateway versions", %{
      account: account,
      gateway_group: gateway_group,
      dns_resource: resource,
      dns_resource_policy: policy,
      membership: membership,
      subject: subject,
      client: client,
      socket: socket
    } do
      global_relay_group = Fixtures.Relays.create_global_group()

      relay =
        Fixtures.Relays.create_relay(
          group: global_relay_group,
          last_seen_remote_ip_location_lat: 37,
          last_seen_remote_ip_location_lon: -120
        )

      :ok = Domain.Relays.connect_relay(relay, Ecto.UUID.generate())

      Fixtures.Relays.update_relay(relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      client = %{client | last_seen_version: "1.4.55"}

      gateway =
        Fixtures.Gateways.create_gateway(
          account: account,
          group: gateway_group,
          context:
            Fixtures.Auth.build_context(
              type: :gateway_group,
              user_agent: "Linux/24.04 connlib/1.0.412"
            )
        )

      :ok = Domain.Gateways.Presence.connect(gateway)

      :ok = Domain.PubSub.Account.subscribe(account.id)

      send(socket.channel_pid, {:created, resource})
      send(socket.channel_pid, {:created, policy})
      send(socket.channel_pid, {:created, membership})

      {:ok, _reply, socket} =
        API.Client.Socket
        |> socket("client:#{client.id}", %{
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      assert_push "flow_creation_failed", %{
        reason: :not_found,
        resource_id: resource_id
      }

      assert resource_id == resource.id

      gateway =
        Fixtures.Gateways.create_gateway(
          account: account,
          group: gateway_group,
          context:
            Fixtures.Auth.build_context(
              type: :gateway_group,
              user_agent: "Linux/24.04 connlib/1.4.11"
            )
        )

      :ok = Domain.Gateways.Presence.connect(gateway)

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => []
      })

      gateway_id = gateway.id

      assert_receive {{:authorize_flow, ^gateway_id}, {_channel_pid, _socket_ref}, _payload}
    end

    test "selects already connected gateway", %{
      account: account,
      gateway_group: gateway_group,
      dns_resource: resource,
      dns_resource_policy: policy,
      membership: membership,
      socket: socket
    } do
      global_relay_group = Fixtures.Relays.create_global_group()

      relay =
        Fixtures.Relays.create_relay(
          group: global_relay_group,
          last_seen_remote_ip_location_lat: 37,
          last_seen_remote_ip_location_lon: -120
        )

      :ok = Domain.Relays.connect_relay(relay, Ecto.UUID.generate())

      Fixtures.Relays.update_relay(relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      gateway1 =
        Fixtures.Gateways.create_gateway(
          account: account,
          group: gateway_group
        )

      :ok = Domain.Gateways.Presence.connect(gateway1)

      gateway2 =
        Fixtures.Gateways.create_gateway(
          account: account,
          group: gateway_group
        )

      :ok = Domain.Gateways.Presence.connect(gateway2)

      :ok = Domain.PubSub.Account.subscribe(account.id)

      send(socket.channel_pid, {:created, resource})
      send(socket.channel_pid, {:created, policy})
      send(socket.channel_pid, {:created, membership})

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => [gateway2.id]
      })

      gateway_id = gateway2.id

      assert_receive {{:authorize_flow, ^gateway_id}, {_channel_pid, _socket_ref}, %{}}

      assert Repo.get_by(Domain.Flows.Flow,
               resource_id: resource.id,
               gateway_id: gateway2.id,
               account_id: account.id
             )

      push(socket, "create_flow", %{
        "resource_id" => resource.id,
        "connected_gateway_ids" => [gateway1.id]
      })

      gateway_id = gateway1.id

      assert_receive {{:authorize_flow, ^gateway_id}, {_channel_pid, _socket_ref}, %{}}

      assert Repo.get_by(Domain.Flows.Flow,
               resource_id: resource.id,
               gateway_id: gateway1.id,
               account_id: account.id
             )
    end
  end

  describe "handle_in/3 prepare_connection" do
    test "returns error when resource is not found", %{socket: socket} do
      ref = push(socket, "prepare_connection", %{"resource_id" => Ecto.UUID.generate()})
      assert_reply ref, :error, %{reason: :not_found}
    end

    test "returns error when there are no online relays", %{
      dns_resource: resource,
      socket: socket
    } do
      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})
      assert_reply ref, :error, %{reason: :offline}
    end

    test "returns error when all gateways are offline", %{
      dns_resource: resource,
      socket: socket
    } do
      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})
      assert_reply ref, :error, %{reason: :offline}
    end

    test "returns error when client has no policy allowing access to resource", %{
      account: account,
      socket: socket
    } do
      resource = Fixtures.Resources.create_resource(account: account)

      gateway = Fixtures.Gateways.create_gateway(account: account)
      :ok = Domain.Gateways.Presence.connect(gateway)

      attrs = %{
        "resource_id" => resource.id
      }

      ref = push(socket, "prepare_connection", attrs)
      assert_reply ref, :error, %{reason: :not_found}
    end

    test "returns error when all gateways connected to the resource are offline", %{
      account: account,
      dns_resource: resource,
      socket: socket
    } do
      gateway = Fixtures.Gateways.create_gateway(account: account)
      :ok = Domain.Gateways.Presence.connect(gateway)

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})
      assert_reply ref, :error, %{reason: :offline}
    end

    test "returns online gateway connected to the resource", %{
      dns_resource: resource,
      gateway: gateway,
      socket: socket
    } do
      global_relay_group = Fixtures.Relays.create_global_group()

      global_relay =
        Fixtures.Relays.create_relay(
          group: global_relay_group,
          last_seen_remote_ip_location_lat: 37,
          last_seen_remote_ip_location_lon: -120
        )

      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(global_relay, stamp_secret)

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      :ok = Domain.Gateways.Presence.connect(gateway)

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})
      resource_id = resource.id

      assert_reply ref, :ok, %{
        gateway_id: gateway_id,
        gateway_remote_ip: gateway_last_seen_remote_ip,
        resource_id: ^resource_id
      }

      assert gateway_id == gateway.id
      assert gateway_last_seen_remote_ip == gateway.last_seen_remote_ip
    end

    test "does not return gateways that do not support the resource", %{
      account: account,
      dns_resource: dns_resource,
      internet_resource: internet_resource,
      socket: socket
    } do
      gateway = Fixtures.Gateways.create_gateway(account: account)
      :ok = Domain.Gateways.Presence.connect(gateway)

      ref = push(socket, "prepare_connection", %{"resource_id" => dns_resource.id})
      assert_reply ref, :error, %{reason: :offline}

      ref = push(socket, "prepare_connection", %{"resource_id" => internet_resource.id})
      assert_reply ref, :error, %{reason: :offline}
    end

    test "returns gateway that support the DNS resource address syntax", %{
      account: account,
      actor_group: actor_group,
      membership: membership,
      socket: socket
    } do
      global_relay_group = Fixtures.Relays.create_global_group()
      global_relay = Fixtures.Relays.create_relay(group: global_relay_group)
      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(global_relay, stamp_secret)

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      gateway_group = Fixtures.Gateways.create_group(account: account)

      gateway =
        Fixtures.Gateways.create_gateway(
          account: account,
          group: gateway_group,
          context: %{
            user_agent: "iOS/12.5 (iPhone) connlib/1.1.0"
          }
        )

      resource =
        Fixtures.Resources.create_resource(
          address: "foo.*.example.com",
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group,
          resource: resource
        )

      :ok = Domain.Gateways.Presence.connect(gateway)

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})
      resource_id = resource.id

      assert_reply ref, :error, %{reason: :not_found}

      gateway =
        Fixtures.Gateways.create_gateway(
          account: account,
          group: gateway_group,
          context: %{
            user_agent: "iOS/12.5 (iPhone) connlib/1.2.0"
          }
        )

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      :ok = Domain.Gateways.Presence.connect(gateway)
      :ok = Domain.PubSub.Account.subscribe(account.id)

      send(socket.channel_pid, {:created, resource})
      send(socket.channel_pid, {:created, policy})
      send(socket.channel_pid, {:created, membership})

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})

      assert_reply ref, :ok, %{
        gateway_id: gateway_id,
        gateway_remote_ip: gateway_last_seen_remote_ip,
        resource_id: ^resource_id
      }

      assert gateway_id == gateway.id
      assert gateway_last_seen_remote_ip == gateway.last_seen_remote_ip
    end

    test "returns gateway that support Internet resources", %{
      account: account,
      internet_gateway_group: internet_gateway_group,
      internet_resource: resource,
      socket: socket
    } do
      account =
        Fixtures.Accounts.update_account(account,
          features: %{
            internet_resource: true
          }
        )

      global_relay_group = Fixtures.Relays.create_global_group()
      global_relay = Fixtures.Relays.create_relay(group: global_relay_group)
      stamp_secret = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(global_relay, stamp_secret)

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      gateway =
        Fixtures.Gateways.create_gateway(
          account: account,
          group: internet_gateway_group,
          context: %{
            user_agent: "iOS/12.5 (iPhone) connlib/1.2.0"
          }
        )

      :ok = Domain.Gateways.Presence.connect(gateway)

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})
      resource_id = resource.id

      assert_reply ref, :error, %{reason: :not_found}

      gateway =
        Fixtures.Gateways.create_gateway(
          account: account,
          group: internet_gateway_group,
          context: %{
            user_agent: "iOS/12.5 (iPhone) connlib/1.3.0"
          }
        )

      Fixtures.Relays.update_relay(global_relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      :ok = Domain.Gateways.Presence.connect(gateway)

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})

      assert_reply ref, :ok, %{
        gateway_id: gateway_id,
        gateway_remote_ip: gateway_last_seen_remote_ip,
        resource_id: ^resource_id
      }

      assert gateway_id == gateway.id
      assert gateway_last_seen_remote_ip == gateway.last_seen_remote_ip
    end

    test "works with service accounts", %{
      account: account,
      dns_resource: resource,
      gateway: gateway,
      actor_group: actor_group
    } do
      actor = Fixtures.Actors.create_actor(type: :service_account, account: account)
      client = Fixtures.Clients.create_client(account: account, actor: actor)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

      {:ok, _reply, socket} =
        API.Client.Socket
        |> socket("client:#{client.id}", %{
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      global_relay_group = Fixtures.Relays.create_global_group()

      relay =
        Fixtures.Relays.create_relay(
          group: global_relay_group,
          last_seen_remote_ip_location_lat: 37,
          last_seen_remote_ip_location_lon: -120
        )

      :ok = Domain.Relays.connect_relay(relay, Ecto.UUID.generate())

      Fixtures.Relays.update_relay(relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      :ok = Domain.Gateways.Presence.connect(gateway)

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})

      assert_reply ref, :ok, %{}
    end

    test "selects compatible gateway versions", %{
      account: account,
      gateway_group: gateway_group,
      dns_resource: resource,
      subject: subject,
      client: client
    } do
      global_relay_group = Fixtures.Relays.create_global_group()

      relay =
        Fixtures.Relays.create_relay(
          group: global_relay_group,
          last_seen_remote_ip_location_lat: 37,
          last_seen_remote_ip_location_lon: -120
        )

      :ok = Domain.Relays.connect_relay(relay, Ecto.UUID.generate())

      Fixtures.Relays.update_relay(relay,
        last_seen_at: DateTime.utc_now() |> DateTime.add(-10, :second)
      )

      client = %{client | last_seen_version: "1.1.55"}

      gateway =
        Fixtures.Gateways.create_gateway(
          account: account,
          group: gateway_group,
          context:
            Fixtures.Auth.build_context(
              type: :gateway_group,
              user_agent: "Linux/24.04 connlib/1.0.412"
            )
        )

      :ok = Domain.Gateways.Presence.connect(gateway)

      {:ok, _reply, socket} =
        API.Client.Socket
        |> socket("client:#{client.id}", %{
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})

      assert_reply ref, :error, %{reason: :not_found}

      gateway =
        Fixtures.Gateways.create_gateway(
          account: account,
          group: gateway_group,
          context:
            Fixtures.Auth.build_context(
              type: :gateway_group,
              user_agent: "Linux/24.04 connlib/1.1.11"
            )
        )

      :ok = Domain.Gateways.Presence.connect(gateway)

      ref = push(socket, "prepare_connection", %{"resource_id" => resource.id})

      assert_reply ref, :ok, %{}
    end
  end

  describe "handle_in/3 reuse_connection" do
    test "returns error when resource is not found", %{gateway: gateway, socket: socket} do
      attrs = %{
        "resource_id" => Ecto.UUID.generate(),
        "gateway_id" => gateway.id,
        "payload" => "DNS_Q"
      }

      ref = push(socket, "reuse_connection", attrs)
      assert_reply ref, :error, %{reason: :not_found}
    end

    test "returns error when gateway is not found", %{dns_resource: resource, socket: socket} do
      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => Ecto.UUID.generate(),
        "payload" => "DNS_Q"
      }

      ref = push(socket, "reuse_connection", attrs)
      assert_reply ref, :error, %{reason: :not_found}
    end

    test "returns error when gateway is not connected to resource", %{
      account: account,
      dns_resource: resource,
      socket: socket
    } do
      gateway = Fixtures.Gateways.create_gateway(account: account)
      :ok = Domain.Gateways.Presence.connect(gateway)

      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "payload" => "DNS_Q"
      }

      ref = push(socket, "reuse_connection", attrs)
      assert_reply ref, :error, %{reason: :offline}
    end

    test "returns error when flow is not authorized due to failing conditions", %{
      account: account,
      client: client,
      actor_group: actor_group,
      membership: membership,
      gateway_group: gateway_group,
      gateway: gateway,
      socket: socket
    } do
      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group,
          resource: resource,
          conditions: [
            %{
              property: :remote_ip_location_region,
              operator: :is_not_in,
              values: [client.last_seen_remote_ip_location_region]
            }
          ]
        )

      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "payload" => "DNS_Q"
      }

      :ok = Domain.Gateways.Presence.connect(gateway)
      :ok = Domain.PubSub.Account.subscribe(account.id)

      send(socket.channel_pid, {:created, resource})
      send(socket.channel_pid, {:created, policy})
      send(socket.channel_pid, {:created, membership})

      ref = push(socket, "reuse_connection", attrs)

      assert_reply ref, :error, %{
        reason: :forbidden,
        violated_properties: [:remote_ip_location_region]
      }
    end

    test "returns error when client has no policy allowing access to resource", %{
      account: account,
      socket: socket
    } do
      resource = Fixtures.Resources.create_resource(account: account)

      gateway = Fixtures.Gateways.create_gateway(account: account)
      :ok = Domain.Gateways.Presence.connect(gateway)

      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "payload" => "DNS_Q"
      }

      ref = push(socket, "reuse_connection", attrs)
      assert_reply ref, :error, %{reason: :not_found}
    end

    test "returns error when gateway is offline", %{
      dns_resource: resource,
      gateway: gateway,
      socket: socket
    } do
      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "payload" => "DNS_Q"
      }

      ref = push(socket, "reuse_connection", attrs)
      assert_reply ref, :error, %{reason: :offline}
    end

    test "broadcasts allow_access to the gateways and then returns connect message", %{
      dns_resource: resource,
      dns_resource_policy: policy,
      membership: membership,
      gateway: gateway,
      client: client,
      socket: socket
    } do
      public_key = gateway.public_key
      resource_id = resource.id
      client_id = client.id

      :ok = Domain.Gateways.Presence.connect(gateway)
      :ok = Domain.PubSub.Account.subscribe(resource.account_id)

      send(socket.channel_pid, {:created, resource})
      send(socket.channel_pid, {:created, policy})
      send(socket.channel_pid, {:created, membership})

      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "payload" => "DNS_Q"
      }

      ref = push(socket, "reuse_connection", attrs)

      gateway_id = gateway.id

      assert_receive {{:allow_access, ^gateway_id}, {channel_pid, socket_ref}, payload}

      assert %{
               resource: recv_resource,
               client: recv_client,
               authorization_expires_at: authorization_expires_at,
               client_payload: "DNS_Q"
             } = payload

      assert recv_resource.id == resource_id
      assert recv_client.id == client_id
      assert authorization_expires_at == socket.assigns.subject.expires_at

      send(
        channel_pid,
        {:connect, socket_ref, resource.id, gateway.public_key, "DNS_RPL"}
      )

      assert_reply ref, :ok, %{
        resource_id: ^resource_id,
        persistent_keepalive: 25,
        gateway_public_key: ^public_key,
        gateway_payload: "DNS_RPL"
      }
    end

    test "works with service accounts", %{
      account: account,
      dns_resource: resource,
      dns_resource_policy: policy,
      membership: membership,
      gateway: gateway,
      gateway_group_token: gateway_group_token,
      actor_group: actor_group
    } do
      actor = Fixtures.Actors.create_actor(type: :service_account, account: account)
      client = Fixtures.Clients.create_client(account: account, actor: actor)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

      {:ok, _reply, socket} =
        API.Client.Socket
        |> socket("client:#{client.id}", %{
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      :ok = Domain.Gateways.Presence.connect(gateway)
      Phoenix.PubSub.subscribe(Domain.PubSub, Domain.Tokens.socket_id(gateway_group_token))

      :ok = Domain.PubSub.Account.subscribe(account.id)

      send(socket.channel_pid, {:created, resource})
      send(socket.channel_pid, {:created, policy})
      send(socket.channel_pid, {:created, membership})

      push(socket, "reuse_connection", %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "payload" => "DNS_Q"
      })

      gateway_id = gateway.id

      assert_receive {{:allow_access, ^gateway_id}, _refs, _payload}
    end
  end

  describe "handle_in/3 request_connection" do
    test "returns error when resource is not found", %{gateway: gateway, socket: socket} do
      attrs = %{
        "resource_id" => Ecto.UUID.generate(),
        "gateway_id" => gateway.id,
        "client_payload" => "RTC_SD",
        "client_preshared_key" => "PSK"
      }

      ref = push(socket, "request_connection", attrs)
      assert_reply ref, :error, %{reason: :not_found}
    end

    test "returns error when gateway is not found", %{dns_resource: resource, socket: socket} do
      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => Ecto.UUID.generate(),
        "client_payload" => "RTC_SD",
        "client_preshared_key" => "PSK"
      }

      ref = push(socket, "request_connection", attrs)
      assert_reply ref, :error, %{reason: :not_found}
    end

    test "returns error when gateway is not connected to resource", %{
      account: account,
      dns_resource: resource,
      socket: socket
    } do
      gateway = Fixtures.Gateways.create_gateway(account: account)
      :ok = Domain.Gateways.Presence.connect(gateway)

      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "client_payload" => "RTC_SD",
        "client_preshared_key" => "PSK"
      }

      ref = push(socket, "request_connection", attrs)
      assert_reply ref, :error, %{reason: :offline}
    end

    test "returns error when client has no policy allowing access to resource", %{
      account: account,
      socket: socket
    } do
      resource = Fixtures.Resources.create_resource(account: account)

      gateway = Fixtures.Gateways.create_gateway(account: account)
      :ok = Domain.Gateways.Presence.connect(gateway)

      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "client_payload" => "RTC_SD",
        "client_preshared_key" => "PSK"
      }

      ref = push(socket, "request_connection", attrs)
      assert_reply ref, :error, %{reason: :not_found}
    end

    test "returns error when flow is not authorized due to failing conditions", %{
      account: account,
      client: client,
      actor_group: actor_group,
      membership: membership,
      gateway_group: gateway_group,
      gateway: gateway,
      socket: socket
    } do
      resource =
        Fixtures.Resources.create_resource(
          account: account,
          connections: [%{gateway_group_id: gateway_group.id}]
        )

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          actor_group: actor_group,
          resource: resource,
          conditions: [
            %{
              property: :remote_ip_location_region,
              operator: :is_not_in,
              values: [client.last_seen_remote_ip_location_region]
            }
          ]
        )

      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "client_payload" => "RTC_SD",
        "client_preshared_key" => "PSK"
      }

      :ok = Domain.Gateways.Presence.connect(gateway)

      :ok = Domain.PubSub.Account.subscribe(account.id)

      send(socket.channel_pid, {:created, resource})
      send(socket.channel_pid, {:created, policy})
      send(socket.channel_pid, {:created, membership})

      ref = push(socket, "request_connection", attrs)

      assert_reply ref, :error, %{
        reason: :forbidden,
        violated_properties: [:remote_ip_location_region]
      }
    end

    test "returns error when gateway is offline", %{
      dns_resource: resource,
      gateway: gateway,
      socket: socket
    } do
      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "client_payload" => "RTC_SD",
        "client_preshared_key" => "PSK"
      }

      ref = push(socket, "request_connection", attrs)
      assert_reply ref, :error, %{reason: :offline}
    end

    test "broadcasts request_connection to the gateways and then returns connect message", %{
      dns_resource: resource,
      gateway_group_token: gateway_group_token,
      gateway: gateway,
      client: client,
      socket: socket
    } do
      public_key = gateway.public_key
      resource_id = resource.id
      client_id = client.id

      :ok = Domain.Gateways.Presence.connect(gateway)
      Domain.PubSub.subscribe(Domain.Tokens.socket_id(gateway_group_token))

      :ok = Domain.PubSub.Account.subscribe(resource.account_id)

      attrs = %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "client_payload" => "RTC_SD",
        "client_preshared_key" => "PSK"
      }

      ref = push(socket, "request_connection", attrs)

      gateway_id = gateway.id

      assert_receive {{:request_connection, ^gateway_id}, {channel_pid, socket_ref}, payload}

      assert %{
               resource: recv_resource,
               client: recv_client,
               client_preshared_key: "PSK",
               client_payload: "RTC_SD",
               authorization_expires_at: authorization_expires_at
             } = payload

      assert recv_resource.id == resource_id
      assert recv_client.id == client_id

      assert authorization_expires_at == socket.assigns.subject.expires_at

      send(
        channel_pid,
        {:connect, socket_ref, resource.id, gateway.public_key, "FULL_RTC_SD"}
      )

      assert_reply ref, :ok, %{
        resource_id: ^resource_id,
        persistent_keepalive: 25,
        gateway_public_key: ^public_key,
        gateway_payload: "FULL_RTC_SD"
      }
    end

    test "works with service accounts", %{
      account: account,
      dns_resource: resource,
      gateway_group_token: gateway_group_token,
      gateway: gateway,
      actor_group: actor_group
    } do
      actor = Fixtures.Actors.create_actor(type: :service_account, account: account)
      client = Fixtures.Clients.create_client(account: account, actor: actor)
      Fixtures.Actors.create_membership(account: account, actor: actor, group: actor_group)

      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

      {:ok, _reply, socket} =
        API.Client.Socket
        |> socket("client:#{client.id}", %{
          client: client,
          subject: subject
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      :ok = Domain.Gateways.Presence.connect(gateway)
      Phoenix.PubSub.subscribe(Domain.PubSub, Domain.Tokens.socket_id(gateway_group_token))

      :ok = Domain.PubSub.Account.subscribe(account.id)

      push(socket, "request_connection", %{
        "resource_id" => resource.id,
        "gateway_id" => gateway.id,
        "client_payload" => "RTC_SD",
        "client_preshared_key" => "PSK"
      })

      gateway_id = gateway.id

      assert_receive {{:request_connection, ^gateway_id}, _refs, _payload}
    end
  end

  describe "handle_in/3 broadcast_ice_candidates" do
    test "does nothing when gateways list is empty", %{
      socket: socket
    } do
      candidates = ["foo", "bar"]

      attrs = %{
        "candidates" => candidates,
        "gateway_ids" => []
      }

      push(socket, "broadcast_ice_candidates", attrs)
      refute_receive {:ice_candidates, _client_id, _candidates}
    end

    test "broadcasts :ice_candidates message to all gateways", %{
      client: client,
      gateway_group_token: gateway_group_token,
      gateway: gateway,
      socket: socket
    } do
      candidates = ["foo", "bar"]

      attrs = %{
        "candidates" => candidates,
        "gateway_ids" => [gateway.id]
      }

      :ok = Domain.Gateways.Presence.connect(gateway)
      Domain.PubSub.subscribe(Domain.Tokens.socket_id(gateway_group_token))

      :ok = Domain.PubSub.Account.subscribe(client.account_id)

      push(socket, "broadcast_ice_candidates", attrs)

      gateway_id = gateway.id

      assert_receive {{:ice_candidates, ^gateway_id}, client_id, ^candidates}, 200
      assert client.id == client_id
    end
  end

  describe "handle_in/3 broadcast_invalidated_ice_candidates" do
    test "does nothing when gateways list is empty", %{
      socket: socket
    } do
      candidates = ["foo", "bar"]

      attrs = %{
        "candidates" => candidates,
        "gateway_ids" => []
      }

      push(socket, "broadcast_invalidated_ice_candidates", attrs)
      refute_receive {:invalidate_ice_candidates, _client_id, _candidates}
    end

    test "broadcasts :invalidate_ice_candidates message to all gateways", %{
      client: client,
      gateway_group_token: gateway_group_token,
      gateway: gateway,
      socket: socket
    } do
      candidates = ["foo", "bar"]

      attrs = %{
        "candidates" => candidates,
        "gateway_ids" => [gateway.id]
      }

      :ok = Domain.Gateways.Presence.connect(gateway)
      Domain.PubSub.subscribe(Domain.Tokens.socket_id(gateway_group_token))
      :ok = Domain.PubSub.Account.subscribe(client.account_id)

      push(socket, "broadcast_invalidated_ice_candidates", attrs)

      gateway_id = gateway.id

      assert_receive {{:invalidate_ice_candidates, ^gateway_id}, client_id, ^candidates}, 200
      assert client.id == client_id
    end
  end

  # Debouncer tests
  describe "handle_info/3" do
    test "push_leave cancels leave if reconnecting with the same stamp secret" do
      relay_group = Fixtures.Relays.create_global_group()

      relay1 = Fixtures.Relays.create_relay(group: relay_group)
      stamp_secret1 = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(relay1, stamp_secret1)

      assert_push "relays_presence",
                  %{
                    connected: [relay_view1, relay_view2],
                    disconnected_ids: []
                  },
                  relays_presence_timeout() + 10

      assert relay1.id == relay_view1.id
      assert relay1.id == relay_view2.id

      Fixtures.Relays.disconnect_relay(relay1)

      # presence_diff isn't immediate
      Process.sleep(1)

      # Reconnect with the same stamp secret
      :ok = Domain.Relays.connect_relay(relay1, stamp_secret1)

      # Should not receive any disconnect
      relay_id = relay1.id

      refute_push "relays_presence",
                  %{
                    connected: [],
                    disconnected_ids: [^relay_id]
                  },
                  relays_presence_timeout() + 10
    end

    test "push_leave disconnects immediately if reconnecting with a different stamp secret" do
      relay_group = Fixtures.Relays.create_global_group()

      relay1 = Fixtures.Relays.create_relay(group: relay_group)
      stamp_secret1 = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(relay1, stamp_secret1)

      assert_push "relays_presence",
                  %{
                    connected: [relay_view1, relay_view2],
                    disconnected_ids: []
                  },
                  relays_presence_timeout() + 10

      assert relay1.id == relay_view1.id
      assert relay1.id == relay_view2.id

      Fixtures.Relays.disconnect_relay(relay1)

      # presence_diff isn't immediate
      Process.sleep(1)

      # Reconnect with a different stamp secret
      stamp_secret2 = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(relay1, stamp_secret2)

      # Should receive disconnect "immediately"
      assert_push "relays_presence",
                  %{
                    connected: [relay_view1, relay_view2],
                    disconnected_ids: [relay_id]
                  },
                  relays_presence_timeout() + 10

      assert relay_view1.id == relay1.id
      assert relay_view2.id == relay1.id
      assert relay_id == relay1.id
    end

    test "push_leave disconnects after the debounce timeout expires" do
      relay_group = Fixtures.Relays.create_global_group()

      relay1 = Fixtures.Relays.create_relay(group: relay_group)
      stamp_secret1 = Ecto.UUID.generate()
      :ok = Domain.Relays.connect_relay(relay1, stamp_secret1)

      assert_push "relays_presence",
                  %{
                    connected: [relay_view1, relay_view2],
                    disconnected_ids: []
                  },
                  relays_presence_timeout() + 10

      assert relay1.id == relay_view1.id
      assert relay1.id == relay_view2.id

      Fixtures.Relays.disconnect_relay(relay1)

      # Should receive disconnect after timeout
      assert_push "relays_presence",
                  %{
                    connected: [],
                    disconnected_ids: [relay_id]
                  },
                  relays_presence_timeout() + 10

      assert relay_id == relay1.id
    end

    test "for unknown messages it doesn't crash", %{socket: socket} do
      ref = push(socket, "unknown_message", %{})
      assert_reply ref, :error, %{reason: :unknown_message}
    end
  end

  defp relays_presence_timeout do
    Application.fetch_env!(:api, :relays_presence_debounce_timeout_ms) + 10
  end
end
