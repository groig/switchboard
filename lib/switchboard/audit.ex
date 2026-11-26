defmodule Switchboard.Audit do
  @moduledoc """
  The audit log: every MCP tool call and every web action.

  Rows record who, through which client, what (tool or action), the arguments (secrets redacted,
  long values truncated), the outcome, duration, result size and which upstreams were called.
  The table is append-only (a trigger refuses updates and deletes); `Switchboard.Audit.Prune`
  removes rows older than the retention (default 180 days) through the one allowed path.
  """
  import Ecto.Query

  alias Switchboard.Audit.Event
  alias Switchboard.{Repo, Scope}

  @outcomes ~w(ok error denied rate_limited disabled)
  @string_cap 200
  @list_cap 20
  @args_cap 4_000

  # Argument names that are always redacted, whatever the tool says.
  @sensitive ~r/token|secret|password|passwd|api_?key|authorization|credential|cookie/i

  def outcomes, do: @outcomes

  @doc "Records a web action by the scope's user (`outcome: \"ok\"` unless given)."
  def log_web(%Scope{} = scope, action, args \\ %{}, opts \\ []) do
    insert(scope, "web", action, args, opts)
  end

  @doc """
  Records an MCP tool call. `opts`: `:outcome`, `:error`, `:duration_ms`, `:result_bytes`,
  `:upstreams` and `:sensitive` (argument names the tool flags as sensitive).
  """
  def log_tool(%Scope{} = scope, tool, args, opts) do
    insert(scope, "mcp", tool, args, opts)
  end

  defp insert(scope, kind, action, args, opts) do
    user = scope.user
    outcome = Keyword.get(opts, :outcome, "ok")
    true = outcome in @outcomes

    event =
      Repo.insert!(%Event{
        at: DateTime.utc_now(),
        user_id: user && user.id,
        username: user && user.username,
        kind: kind,
        action: action,
        client_id: scope.client_id,
        client_name: scope.client_name,
        args: redact(args, Keyword.get(opts, :sensitive, [])),
        outcome: outcome,
        error: opts[:error] && String.slice(to_string(opts[:error]), 0, 500),
        duration_ms: opts[:duration_ms],
        result_bytes: opts[:result_bytes],
        upstreams: opts[:upstreams] || [],
        ip: scope.ip
      })

    if user, do: broadcast(user.id, event)
    event
  end

  @doc """
  Subscribes the caller to the user's new audit rows, delivered as
  `{:audit_event, %{kind:, action:, outcome:}}` (the Get started checklist ticks off live).
  """
  def subscribe_user(user_id), do: Phoenix.PubSub.subscribe(Switchboard.PubSub, topic(user_id))

  defp topic(user_id), do: "audit:user:" <> user_id

  defp broadcast(user_id, %Event{} = e) do
    Phoenix.PubSub.broadcast(
      Switchboard.PubSub,
      topic(user_id),
      {:audit_event, %{kind: e.kind, action: e.action, outcome: e.outcome}}
    )
  end

  @doc """
  Redacts and truncates arguments for storage: values of sensitive keys (by name, or listed in
  `sensitive`) become `"[redacted]"`, strings are cut at #{@string_cap} characters, lists at
  #{@list_cap} items, and an oversized result is replaced by a note.
  """
  def redact(args, sensitive \\ []) when is_map(args) do
    sensitive = MapSet.new(sensitive, &to_string/1)
    redacted = do_redact(args, sensitive, 0)

    if byte_size(Jason.encode!(redacted)) > @args_cap,
      do: %{"_truncated" => "arguments too large to store"},
      else: redacted
  end

  defp do_redact(%{} = map, sensitive, depth) when depth < 4 do
    Map.new(map, fn {k, v} ->
      key = to_string(k)

      if MapSet.member?(sensitive, key) or key =~ @sensitive,
        do: {key, "[redacted]"},
        else: {key, do_redact(v, sensitive, depth + 1)}
    end)
  end

  defp do_redact(%{}, _sensitive, _depth), do: "[nested]"

  defp do_redact(list, sensitive, depth) when is_list(list) do
    {head, rest} = Enum.split(list, @list_cap)
    items = Enum.map(head, &do_redact(&1, sensitive, depth + 1))
    if rest == [], do: items, else: items ++ ["… #{length(rest)} more"]
  end

  defp do_redact(s, _sensitive, _depth) when is_binary(s) do
    if String.length(s) > @string_cap, do: String.slice(s, 0, @string_cap) <> "…", else: s
  end

  defp do_redact(v, _sensitive, _depth) when is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp do_redact(v, _sensitive, _depth) when is_atom(v), do: Atom.to_string(v)
  defp do_redact(v, _sensitive, _depth), do: inspect(v) |> String.slice(0, @string_cap)

  ## Reading

  @doc """
  Lists events, newest first. Filters: `:user_id`, `:username`, `:kind`, `:action`, `:outcome`,
  `:before` (a cursor: `{at, id}` of the last row seen). Returns at most `:limit` (default 50).
  """
  def list(filters \\ %{}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Event
    |> filter(filters)
    |> order_by([e], desc: e.at, desc: e.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "The scope's own events (My activity)."
  def list_mine(%Scope{user: user}, filters \\ %{}, opts \\ []) do
    filters |> Map.put(:user_id, user.id) |> Map.delete(:username) |> list(opts)
  end

  defp filter(query, filters) do
    Enum.reduce(filters, query, fn
      {_key, value}, q when value in [nil, ""] -> q
      {:user_id, id}, q -> where(q, [e], e.user_id == ^id)
      {:username, name}, q -> where(q, [e], e.username == ^name)
      {:kind, kind}, q -> where(q, [e], e.kind == ^kind)
      {:action, action}, q -> where(q, [e], e.action == ^action)
      {:outcome, outcome}, q -> where(q, [e], e.outcome == ^outcome)
      {:before, {at, id}}, q -> where(q, [e], e.at < ^at or (e.at == ^at and e.id < ^id))
      _, q -> q
    end)
  end

  @doc "Distinct action names seen (for filters)."
  def actions do
    Repo.all(from e in Event, distinct: true, select: e.action, order_by: e.action)
  end

  ## Retention

  def retention_days,
    do: Application.get_env(:switchboard, __MODULE__, []) |> Keyword.get(:retention_days, 180)

  @doc "Deletes rows older than the retention. Returns how many."
  def prune(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -retention_days() * 86_400)

    {:ok, count} =
      Repo.transact(fn ->
        # The append-only trigger lets deletes through only with this transaction-local flag.
        Repo.query!("SET LOCAL switchboard.audit_prune = 'on'")
        {count, _} = Repo.delete_all(from e in Event, where: e.at < ^cutoff)
        {:ok, count}
      end)

    count
  end
end
