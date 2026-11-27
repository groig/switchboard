defmodule Switchboard.Plane.Budget do
  @moduledoc """
  What is left of a Plane key's rate limit, so Switchboard paces itself instead of bursting.

  People's Plane keys allow about 60 requests a minute (`API_KEY_RATE_LIMIT` on the Plane
  server, a sliding window), shared with their other tools. Switchboard knows two things:

    * the requests it sent with the key in the last minute (one row per request, lock-free);
    * what Plane said last: its `X-RateLimit-Remaining` / `X-RateLimit-Reset` headers, and a 429
      (with `Retry-After`), after which the key fails fast until the reset without asking Plane.

  `admit/1` runs before every uncached Plane request. Normally it only counts the request (and
  refuses while a 429 is in force). A caller that reads many items (`plane_get_items`) sets a
  pacing deadline with `pace/2` in its tasks: then `admit/1` waits for the window to free a slot
  while the key is down to its reserve, and gives up with `{:error, {:rate_limited, seconds}}`
  when the wait would pass the deadline.

  Config (`config :switchboard, Switchboard.Plane.Budget`): `limit` (60), `reserve` (requests
  kept for the person's other tools, 8), `window_ms` (60 000).
  """
  use GenServer

  @sent __MODULE__.Sent
  @state __MODULE__.State

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  defp config(key, default),
    do: Application.get_env(:switchboard, __MODULE__, []) |> Keyword.get(key, default)

  def limit, do: config(:limit, 60)
  def reserve, do: config(:reserve, 8)
  defp window, do: config(:window_ms, 60_000)

  defp now, do: System.monotonic_time(:millisecond)

  @doc """
  Pacing for the calling process: until `deadline_ms` (monotonic), uncached requests wait for a
  free slot instead of spending the key's reserve. `pace(nil)` turns it off.
  """
  def pace(nil), do: Process.delete(:plane_pace)
  def pace(deadline_ms) when is_integer(deadline_ms), do: Process.put(:plane_pace, deadline_ms)

  @doc """
  Before a request with key `kid`: `:ok` (and the request is counted), or
  `{:error, {:rate_limited, seconds}}`.
  """
  def admit(kid) do
    case blocked_ms(kid) do
      ms when ms > 0 ->
        {:error, {:rate_limited, seconds(ms)}}

      _ ->
        case Process.get(:plane_pace) do
          nil -> take(kid)
          deadline -> paced(kid, deadline)
        end
    end
  end

  defp paced(kid, deadline) do
    if remaining(kid) > reserve() do
      take(kid)
    else
      wait = max(free_in(kid), 50)

      if now() + wait <= deadline do
        Process.sleep(min(wait, 1_000))
        admit(kid)
      else
        {:error, {:rate_limited, seconds(wait)}}
      end
    end
  end

  defp take(kid) do
    :ets.insert(@sent, {kid, now()})
    :ok
  end

  @doc "Records what Plane said about the key in a response (headers, 429)."
  def record(kid, {:ok, %Req.Response{status: status} = resp}) do
    at = now()

    case header_int(resp, "x-ratelimit-remaining") do
      n when is_integer(n) ->
        :ets.insert(@state, {{:header, kid}, n, at, reset_at(resp, at)})

      _ ->
        :ok
    end

    if status == 429 do
      ms =
        case header_int(resp, "retry-after") do
          s when is_integer(s) and s > 0 -> s * 1_000
          _ -> (reset_at(resp, at) || at + window()) - at
        end

      :ets.insert(@state, {{:blocked, kid}, at + max(ms, 1_000)})
    end

    :ok
  end

  def record(_kid, _other), do: :ok

  # X-RateLimit-Reset: Plane sends a Unix time; accept a number of seconds as well.
  defp reset_at(resp, at) do
    case header_int(resp, "x-ratelimit-reset") do
      n when is_integer(n) and n > 1_000_000_000 ->
        at + max(n - System.os_time(:second), 0) * 1_000

      n when is_integer(n) and n >= 0 ->
        at + n * 1_000

      _ ->
        nil
    end
  end

  defp header_int(resp, name) do
    with [value | _] <- Req.Response.get_header(resp, name),
         {n, _} <- Integer.parse(String.trim(value)) do
      n
    else
      _ -> nil
    end
  end

  @doc "Requests the key may still send in the current window (Switchboard's best estimate)."
  def remaining(kid), do: kid |> estimate() |> elem(0)

  # {remaining, ms until a slot frees}: our own count of the window, or Plane's last headers
  # when they say less (the person's other tools use the key too).
  defp estimate(kid) do
    t = now()
    sent = sent_since(kid, t - window())
    own = max(limit() - sent, 0)

    own_free =
      case :ets.select(@sent, [{{kid, :"$1"}, [{:>, :"$1", t - window()}], [:"$1"]}]) do
        [] -> 0
        list -> Enum.min(list) + window() - t
      end

    w = window()

    case :ets.lookup(@state, {:header, kid}) do
      [{_, n, seen, reset}]
      when (is_integer(reset) and reset > t) or (is_nil(reset) and t - seen < w) ->
        told = max(n - sent_since(kid, seen), 0)
        if told < own, do: {told, (reset || seen + window()) - t}, else: {own, own_free}

      _ ->
        {own, own_free}
    end
  end

  @doc "Milliseconds until the key can send again without touching its reserve (0 when now)."
  def free_in(kid) do
    case blocked_ms(kid) do
      ms when ms > 0 ->
        ms

      _ ->
        {left, ms} = estimate(kid)
        if left > reserve(), do: 0, else: max(ms, 0)
    end
  end

  @doc "Seconds until a refused key may try again (after a 429), at least 1."
  def retry_in(kid), do: seconds(max(blocked_ms(kid), 1_000))

  defp blocked_ms(kid) do
    case :ets.lookup(@state, {:blocked, kid}) do
      [{_, until}] -> until - now()
      [] -> 0
    end
  end

  defp sent_since(kid, since),
    do: :ets.select_count(@sent, [{{kid, :"$1"}, [{:>, :"$1", since}], [true]}])

  defp seconds(ms), do: max(div(ms + 999, 1_000), 1)

  @doc "Forgets everything (tests)."
  def reset do
    :ets.delete_all_objects(@sent)
    :ets.delete_all_objects(@state)
  end

  @impl true
  def init(_) do
    :ets.new(@sent, [:named_table, :public, :duplicate_bag, write_concurrency: true])
    :ets.new(@state, [:named_table, :public, :set, read_concurrency: true])
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    t = now()
    :ets.select_delete(@sent, [{{:_, :"$1"}, [{:<, :"$1", t - window()}], [true]}])
    :ets.select_delete(@state, [{{{:blocked, :_}, :"$1"}, [{:<, :"$1", t}], [true]}])
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, :timer.minutes(1))
end
