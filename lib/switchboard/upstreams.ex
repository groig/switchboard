defmodule Switchboard.Upstreams do
  @moduledoc """
  The upstream systems a person can connect, and the one way to call them over HTTP.

  Every upstream request goes through `request/3`: `Req` with options from config (so tests stub
  it with `Req.Test`), timeouts on connect and receive, no retries, no redirects, and a cap on
  the response body, under the system's concurrency limit and circuit breaker
  (`Switchboard.Upstreams.Guard`). Each request is noted for the current tool call's audit row
  and emits `[:switchboard, :upstream, :request]` telemetry.
  """

  @adapters [
    Switchboard.Upstreams.Forgejo,
    Switchboard.Upstreams.Plane,
    Switchboard.Upstreams.Argus,
    Switchboard.Upstreams.Outline,
    Switchboard.Upstreams.RocketChat
  ]

  @max_body 2_000_000

  @doc "Adapter modules, in display order."
  def all, do: @adapters

  @doc "System names (strings), in display order."
  def systems, do: Enum.map(@adapters, & &1.system())

  def fetch(system) when is_binary(system) do
    case Enum.find(@adapters, &(&1.system() == system)) do
      nil -> :error
      mod -> {:ok, mod}
    end
  end

  @doc "A system's configuration (`:url` and any extras like Plane's `:workspace`)."
  def config(system) when is_atom(system) do
    Application.get_env(:switchboard, __MODULE__, []) |> Keyword.get(system, [])
  end

  @doc "A system's base URL, without a trailing slash."
  def base_url(:forgejo), do: Switchboard.Forgejo.Login.base_url()

  def base_url(system),
    do: system |> config() |> Keyword.fetch!(:url) |> String.trim_trailing("/")

  @doc "Every upstream system, as atoms (including the releases service)."
  def atoms, do: [:forgejo, :plane, :argus, :outline, :rocketchat, :releases]

  @doc """
  Performs a request against `system`. `opts` are Req options (`:url`, `:method`, `:headers`,
  `:json`, `:params`...). Returns `{:ok, %Req.Response{}}` with the body decoded when it is JSON,
  or `{:error, reason}` with `reason` one of `:timeout`, `:too_large` or `{:transport, msg}`.
  """
  def request(system, opts, base_url \\ nil) when is_atom(system) do
    Switchboard.Tools.note_upstream(system)
    started = System.monotonic_time()

    result =
      Switchboard.Upstreams.Guard.run(system, fn ->
        result = do_request(system, opts, base_url)
        {breaker_outcome(result), result}
      end)

    :telemetry.execute(
      [:switchboard, :upstream, :request],
      %{duration: System.monotonic_time() - started},
      %{system: system, outcome: telemetry_outcome(result)}
    )

    result
  end

  defp do_request(system, opts, base_url) do
    req =
      Req.new(
        [
          base_url: base_url || base_url(system),
          method: :get,
          receive_timeout: 10_000,
          connect_options: [timeout: 5_000],
          retry: false,
          redirect: false,
          decode_body: false,
          headers: [accept: "application/json", user_agent: "Switchboard"],
          into: &collect_capped/2
        ] ++ (Application.get_env(:switchboard, __MODULE__, [])[:req_options] || [])
      )

    case Req.request(req, opts) do
      {:ok, %Req.Response{} = resp} ->
        if resp.private[:too_large], do: {:error, :too_large}, else: {:ok, decode(resp)}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, e} ->
        {:error, {:transport, Exception.message(e)}}
    end
  end

  # What counts against the breaker: the system being down or slow, not a 4xx.
  defp breaker_outcome({:ok, %Req.Response{status: status}}) when status >= 500, do: :failure
  defp breaker_outcome({:ok, _}), do: :success
  defp breaker_outcome({:error, :too_large}), do: :neutral
  defp breaker_outcome({:error, _}), do: :failure

  defp telemetry_outcome({:ok, %Req.Response{status: status}}), do: status
  defp telemetry_outcome({:error, reason}) when is_atom(reason), do: reason
  defp telemetry_outcome({:error, _}), do: :transport

  defp collect_capped({:data, data}, {req, resp}) do
    body = [resp.body || "" | data]

    if IO.iodata_length(body) > @max_body do
      {:halt, {req, %{resp | body: [], private: Map.put(resp.private, :too_large, true)}}}
    else
      {:cont, {req, %{resp | body: body}}}
    end
  end

  defp decode(%Req.Response{} = resp) do
    body = IO.iodata_to_binary(resp.body || "")

    json? =
      resp |> Req.Response.get_header("content-type") |> Enum.any?(&(&1 =~ "json"))

    case json? && Jason.decode(body) do
      {:ok, decoded} -> %{resp | body: decoded}
      _ -> %{resp | body: body}
    end
  end

  @doc """
  Checks every upstream concurrently: is it reachable, and how fast? Any HTTP answer below 500
  counts as up (a 401 still proves the server is there). Returns
  `[%{system:, label:, url:, status: :up | :down, detail:, ms:}]` in display order.
  """
  def health(timeout \\ 5_000) do
    @adapters
    |> Task.async_stream(&check/1, timeout: timeout, on_timeout: :kill_task, ordered: true)
    |> Enum.zip(@adapters)
    |> Enum.map(fn
      {{:ok, result}, _mod} -> result
      {{:exit, _}, mod} -> %{health_base(mod) | status: :down, detail: "timeout"}
    end)
  end

  defp health_base(mod) do
    %{
      system: mod.system(),
      label: mod.label(),
      url: health_url(mod),
      status: :down,
      detail: nil,
      ms: nil
    }
  end

  defp health_url(mod), do: base_url(atom(mod.system()))

  @atoms %{
    "forgejo" => :forgejo,
    "plane" => :plane,
    "argus" => :argus,
    "outline" => :outline,
    "rocketchat" => :rocketchat
  }

  defp atom(system), do: Map.fetch!(@atoms, system)

  defp check(mod) do
    base = health_base(mod)
    started = System.monotonic_time(:millisecond)
    system = atom(mod.system())

    result =
      request(
        system,
        [url: "/", receive_timeout: 4_000, connect_options: [timeout: 3_000]],
        base.url
      )

    ms = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, %Req.Response{status: status}} when status < 500 ->
        %{base | status: :up, detail: "HTTP #{status}", ms: ms}

      {:ok, %Req.Response{status: status}} ->
        %{base | detail: "HTTP #{status}", ms: ms}

      {:error, reason} ->
        %{base | detail: inspect_reason(reason), ms: ms}
    end
  end

  defp inspect_reason(:timeout), do: "timeout"
  defp inspect_reason({:transport, msg}), do: msg
  defp inspect_reason(other), do: inspect(other)

  @doc """
  The caller's own credential for a system: the Forgejo sign-in token for `:forgejo`, the
  linked secret map otherwise. Never a service credential.
  """
  def credential(%Switchboard.Scope{user: user}, :forgejo),
    do: Switchboard.Connections.forgejo_token(user)

  def credential(%Switchboard.Scope{user: user}, system) when is_atom(system),
    do: Switchboard.Connections.credential(user, Atom.to_string(system))

  @doc """
  Maps a request result to `{:ok, body}` or a reason tools can explain: `:unauthorized`,
  `:not_found`, `:rate_limited`, `{:status, n}`, `:timeout`, `:circuit_open`, `:busy`,
  `:too_large` or `{:transport, msg}`.
  """
  def body({:ok, %Req.Response{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  def body({:ok, %Req.Response{status: status}}) when status in [401, 403],
    do: {:error, :unauthorized}

  def body({:ok, %Req.Response{status: 404}}), do: {:error, :not_found}
  def body({:ok, %Req.Response{status: 429}}), do: {:error, :rate_limited}
  def body({:ok, %Req.Response{status: status}}), do: {:error, {:status, status}}
  def body({:error, reason}), do: {:error, reason}

  @doc "A system's display name."
  def label(:forgejo), do: "Forgejo"
  def label(:plane), do: "Plane"
  def label(:argus), do: "Argus"
  def label(:outline), do: "Outline"
  def label(:rocketchat), do: "Rocket.Chat"
  def label(:releases), do: "Releases"

  @doc """
  One line explaining why a system's part of a result is missing, for the agent to relay.
  """
  def problem(system, reason) do
    name = label(system)
    connect = Switchboard.OAuth.issuer() <> "/connections"

    case reason do
      :not_connected ->
        "#{name} is not connected. Link it at #{connect}"

      :rejected ->
        "#{name} rejected your key. Link it again at #{connect}"

      :unauthorized ->
        "#{name} rejected your key. Link it again at #{connect}"

      :not_found ->
        "#{name}: not found, or you don't have access."

      :rate_limited when system == :plane ->
        "Plane refused the request: your Plane key's rate limit is used up (about 60 requests a minute, shared with your other tools). Try again in a minute."

      :rate_limited ->
        "#{name} rate limit reached. Try again in a minute."

      :timeout ->
        "#{name} didn't answer in time; this part is missing."

      :circuit_open ->
        "#{name} is unavailable right now (failing repeatedly); this part is missing."

      :busy ->
        "#{name} is busy (too many requests through Switchboard); try again shortly."

      :too_large ->
        "#{name} returned more than Switchboard reads; narrow the request."

      :crashed ->
        "#{name}: Switchboard failed reading it; the error was logged."

      :not_configured ->
        "#{name} is not configured on this server."

      :unexpected_response ->
        "#{name} answered something Switchboard doesn't understand."

      {:status, s} ->
        "#{name} answered HTTP #{s}; this part is missing."

      _ ->
        "#{name} is unreachable; this part is missing."
    end
  end

  @doc "Maps a response or error to the usual identity-check outcome."
  def classify({:ok, %Req.Response{status: status}}) when status in [401, 403],
    do: {:error, :unauthorized}

  def classify({:ok, %Req.Response{status: status} = resp}) when status in 200..299,
    do: {:ok, resp}

  def classify({:ok, %Req.Response{status: status}}), do: {:error, {:status, status}}
  def classify({:error, reason}), do: {:error, reason}
end
