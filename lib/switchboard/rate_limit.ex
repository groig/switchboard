defmodule Switchboard.RateLimit do
  @moduledoc """
  A token bucket per key in ETS (single node).

  A bucket holds up to `capacity` tokens and refills continuously at `capacity` per
  `period_ms`, so bursts up to the capacity pass and the sustained rate is the limit. Updates
  are lock-free: compare-and-swap with `:ets.select_replace/2`, retried on contention.

      :ok = RateLimit.take({user_id, "plane_search"}, 60)
      {:error, retry_after_ms} = RateLimit.take(key, 60)
  """
  use GenServer

  @table __MODULE__
  @idle_ms :timer.minutes(10)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Takes one token. `:ok`, or `{:error, ms}` with the time until one is available."
  def take(key, capacity, period_ms \\ 60_000) when capacity > 0 do
    now = System.monotonic_time(:millisecond)
    rate = capacity / period_ms

    case :ets.lookup(@table, key) do
      [] ->
        if :ets.insert_new(@table, {key, capacity - 1.0, now}),
          do: :ok,
          else: take(key, capacity, period_ms)

      [{^key, tokens, at} = old] ->
        available = min(capacity * 1.0, tokens + (now - at) * rate)

        {result, left} =
          if available >= 1.0,
            do: {:ok, available - 1.0},
            else: {{:error, ceil((1.0 - available) / rate)}, available}

        spec = [{old, [], [{:const, {key, left, now}}]}]

        if :ets.select_replace(@table, spec) == 1,
          do: result,
          else: take(key, capacity, period_ms)
    end
  end

  @doc "Empties the table (tests)."
  def reset, do: :ets.delete_all_objects(@table)

  @impl true
  def init(_) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      write_concurrency: true,
      read_concurrency: true
    ])

    schedule_cleanup()
    {:ok, nil}
  end

  @impl true
  def handle_info(:cleanup, state) do
    # Buckets untouched for a while are full again; forgetting them changes nothing.
    cutoff = System.monotonic_time(:millisecond) - @idle_ms
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, :timer.minutes(1))
end
