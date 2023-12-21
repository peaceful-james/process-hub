defprotocol ProcessHub.Strategy.Distribution.Base do
  @moduledoc """
  The distribution strategy protocol provides API functions for distributing child processes.
  """

  @spec belongs_to(
          distribution_strategy :: struct(),
          hub_id :: atom(),
          child_id :: atom() | binary(),
          hub_nodes :: [node()],
          replication_factor :: pos_integer()
        ) :: [node()]
  def belongs_to(strategy, hub_id, child_id, hub_nodes, replication_factor)

  @spec init(distribution_strategy :: struct(), hub_id :: atom(), hub_nodes :: [node()]) :: term()
  def init(strategy, hub_id, hub_nodes)
end
