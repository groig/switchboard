defmodule Switchboard.Cache do
  @moduledoc """
  A small TTL cache in ETS for upstream data that changes rarely and is expensive to fetch
  (Plane projects and states). Keys always include the person, so nothing crosses people.
  Errors are never cached.
  """
  use GenServer

  @table __MODULE__

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Returns the cached value for `key`, or computes it with `fun` (`{:ok, v}` is cached)."
  def fetch(key, ttl_ms, fun) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, value, expires}] when expires > now ->
        {:ok, value}

      _ ->
        with {:ok, value} <- fun.() do
          :ets.insert(@table, {key, value, now + ttl_ms})
          {:ok, value}
        end
    end
  end

  def clear, do: :ets.delete_all_objects(@table)

  @doc "Deletes entries whose key matches an ETS match pattern (`{:plane_get, kid, :_, :_}`)."
  def delete_match(pattern), do: :ets.match_delete(@table, {pattern, :_, :_})

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Process.send_after(self(), :sweep, :timer.minutes(5))
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    Process.send_after(self(), :sweep, :timer.minutes(5))
    {:noreply, state}
  end
end
