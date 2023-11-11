defmodule ProcessHub.Strategy.Synchronization.Gossip do
  @moduledoc """
  The Gossip synchronization strategy provides a method for spreading information to other nodes
  within the `ProcessHub` cluster. It utilizes a gossip protocol to
  synchronize the process registry across the cluster.

  The Gossip strategy is most suitable for clusters are large. It scales well but produces
  higher latency than the PubSub strategy when operating in small clusters.
  When the cluster increases in size, Gossip protocol can also save bandwidth compared to PubSub.

  > The Gossip strategy works as follows:
  > - The synchronization process is initiated on a single node.
  > - The node collects its own local process registry data and appends it to the synchronization data.
  > - It selects a predefined number of nodes that have not yet added their local registry data.
  > - The node sends the data to the selected nodes.
  > - The nodes append their local registry data to the received data and send it to the next nodes.
  > - When all nodes have added their data to the synchronization data, the message will be sent to
  > nodes that have not yet acknowledged the synchronization ack.
  > - If node receives the synchronization data which contains all nodes data, it will
  > synchronize the data with it's local process registry and forward the data to the next nodes
  > that have not yet acknowledged the synchronization ack.
  > - When all nodes in the cluster have acknowledged the synchronization data, the synchronization
  > process is completed and the reference is invalidated.

  Each node also adds a timestamp to the synchronization data. This is used to ensure that
  the synchronization data is not older than the data that is already in the local process registry.
  """

  alias ProcessHub.Strategy.Synchronization.Base, as: SynchronizationStrategy
  alias ProcessHub.Service.LocalStorage
  alias ProcessHub.Service.Cluster
  alias ProcessHub.Service.Synchronizer
  alias ProcessHub.Constant.Event
  alias ProcessHub.Utility.Bag
  alias ProcessHub.Utility.Name

  @typedoc """
  The Gossip strategy configuration options.

  * `sync_interval` - The periodic synchronization interval in milliseconds. The default is `15000`.
  * `recipients` - The number of nodes that will receive the synchronization data and propagate it further. The default is `3`.
  * `restricted_init` - If set to `true`, the synchronization process will only be started on a single node.
    This node is selected by sorting the node names alphabetically and selecting the first node. The default is `true`.
  """
  @type t() :: %__MODULE__{
          sync_interval: pos_integer(),
          recipients: pos_integer(),
          restricted_init: boolean()
        }
  defstruct sync_interval: 15000, recipients: 3, restricted_init: true

  defimpl SynchronizationStrategy, for: ProcessHub.Strategy.Synchronization.Gossip do
    use Event

    @spec propagate(
            ProcessHub.Strategy.Synchronization.Gossip.t(),
            ProcessHub.hub_id(),
            [term()],
            node(),
            :add | :rem
          ) :: :ok
    def propagate(strategy, hub_id, children, update_node, type) do
      ref = make_ref()
      handle_propagation_type(hub_id, children, update_node, type)

      Cluster.nodes(hub_id)
      |> recipients_select(strategy)
      |> propagate_data(hub_id, strategy, {ref, [node()], children, update_node}, type)

      :ok
    end

    @spec handle_propagation(
            ProcessHub.Strategy.Synchronization.Gossip.t(),
            ProcessHub.hub_id(),
            term(),
            :add | :rem
          ) :: :ok
    def handle_propagation(strategy, hub_id, {ref, acks, child_data, update_node}, type) do
      cached_acks =
        case LocalStorage.get(hub_id, ref) do
          nil -> []
          {_, :invalidated, _ttl} -> :invalidated
          {_, cached_acks, _ttl} -> cached_acks
        end

      case cached_acks do
        :invalidated ->
          nil

        _ ->
          acks = Enum.uniq(acks ++ cached_acks)
          unacked_nodes = unacked_nodes(acks, hub_id)

          if length(unacked_nodes) === 0 do
            invalidate_ref(strategy, hub_id, ref)
          end

          acks =
            if Enum.member?(unacked_nodes, node()) do
              handle_propagation_type(hub_id, child_data, update_node, type)

              [node() | acks]
            else
              acks
            end

          LocalStorage.insert(hub_id, ref, acks, strategy.sync_interval)

          recipients_select(unacked_nodes, strategy)
          |> propagate_data(hub_id, strategy, {ref, acks, child_data, update_node}, type)
      end

      :ok
    end

    @spec init_sync(ProcessHub.Strategy.Synchronization.Gossip.t(), ProcessHub.hub_id(), [node()]) ::
            :ok
    def init_sync(strategy, hub_id, cluster_nodes) do
      case strategy.restricted_init do
        true ->
          local_node = node()

          selected_node =
            cluster_nodes
            |> Enum.map(&Atom.to_string(&1))
            |> Enum.sort()
            |> Enum.at(0)

          cluster_nodes = Enum.filter(cluster_nodes, fn node -> local_node !== node end)

          init_sync_internal(
            strategy,
            hub_id,
            cluster_nodes,
            selected_node === Atom.to_string(local_node)
          )

        _ ->
          init_sync_internal(strategy, hub_id, cluster_nodes, true)
      end

      :ok
    end

    @spec handle_synchronization(
            ProcessHub.Strategy.Synchronization.Gossip.t(),
            ProcessHub.hub_id(),
            term(),
            node()
          ) :: :ok
    def handle_synchronization(
          strategy,
          hub_id,
          %{ref: ref, nodes_data: nodes_data, sync_acks: sync_acks},
          _remote_node
        ) do
      case merge_sync_data(hub_id, ref, nodes_data, sync_acks) do
        :invalidated ->
          nil

        {sync_data, sync_acks} ->
          handle_sync_data(strategy, hub_id, ref, sync_data, sync_acks)
      end

      :ok
    end

    @spec handle_sync_data(
            ProcessHub.Strategy.Synchronization.Gossip.t(),
            ProcessHub.hub_id(),
            reference(),
            map(),
            list()
          ) :: :ok
    def handle_sync_data(strategy, hub_id, ref, sync_data, sync_acks) do
      LocalStorage.insert(hub_id, ref, {sync_data, sync_acks}, strategy.sync_interval)
      missing_nodes = missing_nodes(sync_data, hub_id)

      cond do
        length(missing_nodes) === 0 ->
          unacked_nodes = unacked_nodes(sync_acks, hub_id)

          sync_acks =
            if Enum.member?(unacked_nodes, node()) do
              sync_locally(hub_id, sync_data)

              [node() | sync_acks]
            else
              sync_acks
            end

          if length(unacked_nodes) === 0 do
            invalidate_ref(strategy, hub_id, ref)
          else
            forward_data(unacked_nodes, strategy, hub_id, %{
              ref: ref,
              nodes_data: sync_data,
              sync_acks: sync_acks
            })
          end

        length(missing_nodes) > 0 ->
          forward_data(missing_nodes, strategy, hub_id, %{
            ref: ref,
            nodes_data: sync_data,
            sync_acks: sync_acks
          })

        true ->
          throw("Invalid state")
      end
    end

    defp invalidate_ref(strategy, hub_id, ref) do
      LocalStorage.insert(hub_id, ref, :invalidated, strategy.sync_interval)
    end

    defp init_sync_internal(strategy, hub_id, cluster_nodes, true) do
      ref = make_ref()

      sync_data = %{
        node() => {Synchronizer.local_sync_data(hub_id), Bag.timestamp(:microsecond)}
      }

      LocalStorage.insert(hub_id, ref, {sync_data, []}, strategy.sync_interval)

      cluster_nodes
      |> recipients_select(strategy)
      |> forward_data(strategy, hub_id, %{ref: ref, nodes_data: sync_data, sync_acks: []})
    end

    defp init_sync_internal(_strategy, _hub_id, _cluster_nodes, false) do
      :ok
    end

    defp merge_sync_data(hub_id, ref, nodes_data, sync_acks) do
      local_timestamp = Bag.timestamp(:microsecond)
      local_data = Synchronizer.local_sync_data(hub_id)
      nodes_data = Map.put(nodes_data, node(), {local_data, local_timestamp})

      case LocalStorage.get(hub_id, ref) do
        nil ->
          {nodes_data, []}

        {_key, :invalidated, _tt} ->
          :invalidated

        {_key, {cached_data, cached_acks}, _ttl} ->
          merged_data =
            Map.merge(nodes_data, cached_data, fn _node_key, {ld, lt}, {rd, rt} ->
              cond do
                lt > rt -> {ld, lt}
                true -> {rd, rt}
              end
            end)

          {merged_data, Enum.uniq(cached_acks ++ sync_acks)}
      end
    end

    defp sync_locally(hub_id, nodes_data) do
      node_timestamps =
        case LocalStorage.get(hub_id, :gossip_node_timestamps) do
          nil -> %{}
          {_key, node_timestamps, _ttl} -> node_timestamps
        end

      Map.delete(nodes_data, node())
      |> Enum.each(fn {node, {data, timestamp}} ->
        # Make sure that we don't process data that is older than what we already have.
        node_timestamp = Map.get(node_timestamps, node, nil)

        cond do
          node_timestamp === nil ->
            sync_locally_node(hub_id, node, data, timestamp)

          node_timestamp < timestamp ->
            sync_locally_node(hub_id, node, data, timestamp)

          true ->
            :ok
        end
      end)
    end

    defp sync_locally_node(hub_id, node, data, timestamp) do
      Synchronizer.append_data(hub_id, %{node => data})
      Synchronizer.detach_data(hub_id, %{node => data})

      update_node_timestamps(hub_id, node, timestamp)
    end

    defp update_node_timestamps(hub_id, node, timestamp) do
      node_timestamps =
        case :ets.lookup(hub_id, :gossip_node_timestamps) do
          [] -> %{}
          [{_, node_timestamps, _}] -> node_timestamps || %{}
        end
        |> Map.put(node, timestamp)

      :ets.insert(hub_id, {:gossip_node_timestamps, node_timestamps, nil})
    end

    defp unacked_nodes(sync_acks, hub_id) do
      Cluster.nodes(hub_id, [:include_local])
      |> Enum.filter(fn node -> !Enum.member?(sync_acks, node) end)
    end

    defp missing_nodes(nodes_data, hub_id) do
      node_keys = Map.keys(nodes_data)

      Cluster.nodes(hub_id, [:include_local])
      |> Enum.filter(fn node -> !Enum.member?(node_keys, node) end)
    end

    defp forward_data(recipients, strategy, hub_id, sync_data) do
      local_node = node()

      Enum.each(recipients, fn recipient ->
        Node.spawn(recipient, fn ->
          GenServer.cast(
            Name.worker_queue(hub_id),
            {:handle_work,
             fn -> Synchronizer.exec_interval_sync(hub_id, strategy, sync_data, local_node) end}
          )
        end)
      end)
    end

    defp handle_propagation_type(hub_id, children, updated_node, :add) do
      try do
        Name.coordinator(hub_id)
        |> send({@event_children_registration, {children, updated_node}})
      catch
        _, _ -> :ok
      end
    end

    defp handle_propagation_type(hub_id, children, updated_node, :rem) do
      try do
        Name.coordinator(hub_id)
        |> send({@event_children_unregistration, {children, updated_node}})
      catch
        _, _ -> :ok
      end
    end

    defp propagate_data(nodes, hub_id, strategy, data, type) do
      Enum.each(nodes, fn node ->
        Node.spawn(node, fn ->
          GenServer.cast(
            Name.worker_queue(hub_id),
            {:handle_work,
             fn -> SynchronizationStrategy.handle_propagation(strategy, hub_id, data, type) end}
          )
        end)
      end)
    end

    defp recipients_select(nodes, strategy) do
      Enum.take_random(nodes, strategy.recipients)
    end
  end
end
