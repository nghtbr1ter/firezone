defmodule Domain.Events.Hooks do
  @moduledoc """
    A simple behavior to define hooks needed for processing WAL events.
  """

  @callback on_insert(data :: map()) :: :ok | {:error, term()}
  @callback on_update(old_data :: map(), data :: map()) :: :ok | {:error, term()}
  @callback on_delete(old_data :: map()) :: :ok | {:error, term()}
end
