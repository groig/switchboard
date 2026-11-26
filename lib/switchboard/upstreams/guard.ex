defmodule Switchboard.Upstreams.Guard do
  @moduledoc """
  Per-upstream concurrency limits and circuit breakers, for every request in
  `Switchboard.Upstreams.request/3`.

  **Concurrency.** Each system has at most `max_concurrency` requests in flight across all
  people (so twenty agents can't hammer Plane). A caller over the limit waits in a FIFO queue up
  to `acquire_timeout` ms, then gets `{:error, :busy}`. Slots are tied to the caller's pid and
  released when it finishes or dies (a fan-out task killed on timeout can't leak a slot).

  **Circuit breaker.** `threshold` consecutive failures (timeouts, transport errors, 5xx) open
  the breaker for `cooldown` ms: requests fail fast with `{:error, :circuit_open}`. After the
  cooldown one trial request goes through (half-open); success closes the breaker, failure
  opens it again.

  Limits come from `config :switchboard, Switchboard.Upstreams, guard: [...]`, with per-system
  overrides (`plane: [max_concurrency: 4]`).
  """
  use GenServer

  @defaults [max_concurrency: 8, acquire_timeout: 3_000, threshold: 5, cooldown: 30_000]

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Runs `fun` under the system's limit and breaker. `fun` returns `{outcome, result}`."
  def run(system, fun) when is_atom(system) and is_function(fun, 0) do
    case GenServer.call(__MODULE__, {:acquire, system, self()}, :infinity) do
      {:ok, ref} ->
        try do
          {outcome, result} = fun.()
          GenServer.cast(__MODULE__, {:release, system, ref, outcome})
          result
        catch
          kind, reason ->
            GenServer.cast(__MODULE__, {:release, system, ref, :failure})
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The breaker state of each system that has one: `%{plane: :open | :closed | :half_open}`."
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Forgets all state (tests)."
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc "The effective options for a system."
  def options(system) do
    config = Application.get_env(:switchboard, Switchboard.Upstreams, [])[:guard] || []
    base = Keyword.merge(@defaults, Keyword.drop(config, Switchboard.Upstreams.atoms()))
    Keyword.merge(base, config[system] || [])
  end

  ## Server

  # state: %{system => %{in_flight: %{ref => pid}, queue: :queue, failures: n,
  #                      open_until: ms | nil, trial: ref | nil}}

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:acquire, system, pid}, from, state) do
    s = system_state(state, system)
    opts = options(system)
    now = now()

    cond do
      s.open_until && now < s.open_until ->
        {:reply, {:error, :circuit_open}, state}

      # Half-open: one trial at a time.
      s.open_until && s.trial ->
        {:reply, {:error, :circuit_open}, state}

      map_size(s.in_flight) < opts[:max_concurrency] ->
        {ref, s} = grant(s, pid)
        s = if s.open_until, do: %{s | trial: ref}, else: s
        {:reply, {:ok, ref}, Map.put(state, system, s)}

      true ->
        timer = Process.send_after(self(), {:give_up, system, from}, opts[:acquire_timeout])
        s = %{s | queue: :queue.in({from, pid, timer}, s.queue)}
        {:noreply, Map.put(state, system, s)}
    end
  end

  def handle_call(:status, _from, state) do
    now = now()

    status =
      Map.new(state, fn {system, s} ->
        {system,
         cond do
           s.open_until && now < s.open_until -> :open
           s.open_until -> :half_open
           true -> :closed
         end}
      end)

    {:reply, status, state}
  end

  def handle_call(:reset, _from, state) do
    for {_system, s} <- state, {_ref, {_pid, mon}} <- s.in_flight, do: Process.demonitor(mon)
    {:reply, :ok, %{}}
  end

  @impl true
  def handle_cast({:release, system, ref, outcome}, state) do
    {:noreply, release(state, system, ref, outcome)}
  end

  @impl true
  def handle_info({:give_up, system, from}, state) do
    s = system_state(state, system)
    {gone, queue} = take_from_queue(s.queue, from)
    if gone, do: GenServer.reply(from, {:error, :busy})
    {:noreply, Map.put(state, system, %{s | queue: queue})}
  end

  def handle_info({:DOWN, mon, :process, _pid, _reason}, state) do
    # A caller died holding a slot (e.g. a fan-out task killed on timeout).
    found =
      Enum.find_value(state, fn {system, s} ->
        Enum.find_value(s.in_flight, fn {ref, {_pid, m}} -> m == mon && {system, ref} end)
      end)

    case found do
      {system, ref} -> {:noreply, release(state, system, ref, :failure)}
      nil -> {:noreply, state}
    end
  end

  defp release(state, system, ref, outcome) do
    s = system_state(state, system)

    case Map.pop(s.in_flight, ref) do
      {nil, _} ->
        state

      {{_pid, mon}, in_flight} ->
        Process.demonitor(mon, [:flush])
        s = %{s | in_flight: in_flight} |> record(outcome, ref, options(system))
        Map.put(state, system, next_waiter(s, system))
    end
  end

  defp record(s, :success, _ref, _opts), do: %{s | failures: 0, open_until: nil, trial: nil}

  defp record(s, :failure, ref, opts) do
    failures = s.failures + 1

    cond do
      # The half-open trial failed: open again.
      s.trial == ref ->
        %{s | failures: failures, open_until: now() + opts[:cooldown], trial: nil}

      failures >= opts[:threshold] ->
        %{s | failures: failures, open_until: now() + opts[:cooldown]}

      true ->
        %{s | failures: failures}
    end
  end

  # A neutral outcome (e.g. a 4xx) proves the system is up but isn't counted.
  defp record(s, :neutral, ref, opts), do: record(s, :success, ref, opts)

  defp next_waiter(s, system) do
    opts = options(system)

    with true <- map_size(s.in_flight) < opts[:max_concurrency],
         {{:value, {from, pid, timer}}, queue} <- :queue.out(s.queue) do
      Process.cancel_timer(timer)
      s = %{s | queue: queue}

      if s.open_until && now() < s.open_until do
        GenServer.reply(from, {:error, :circuit_open})
        next_waiter(s, system)
      else
        {ref, s} = grant(s, pid)
        GenServer.reply(from, {:ok, ref})
        s
      end
    else
      _ -> s
    end
  end

  defp grant(s, pid) do
    ref = make_ref()
    {ref, %{s | in_flight: Map.put(s.in_flight, ref, {pid, Process.monitor(pid)})}}
  end

  defp take_from_queue(queue, from) do
    list = :queue.to_list(queue)
    {matches, rest} = Enum.split_with(list, fn {f, _pid, _t} -> f == from end)
    {matches != [], :queue.from_list(rest)}
  end

  defp system_state(state, system) do
    Map.get(state, system, %{
      in_flight: %{},
      queue: :queue.new(),
      failures: 0,
      open_until: nil,
      trial: nil
    })
  end

  defp now, do: System.monotonic_time(:millisecond)
end
