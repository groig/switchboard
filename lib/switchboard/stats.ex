defmodule Switchboard.Stats do
  @moduledoc """
  Usage at a glance for `/admin/stats`: aggregated in SQL over `audit_events` (plus `users` and
  `connections`), bucketed by day in the viewer's time zone, cached for a minute per
  period, exclusion list and zone (tests run with `cache: false`, each sandbox seeing its own
  rows).

  Periods: `:launch` (from the local day of the first audit row), `:d30` and `:d7` (the last N
  local days, today included). For the last two, the headline numbers are compared with the
  N days before.

  Every audit query reads MCP rows (`kind = 'mcp'`) in `[from, to)` through the `at` index; the
  period scan is one pass per section (summary for both periods, days, tools, people, clients,
  systems, errors). Excluded people are left out of the audit rows, sign-ups and connections.
  """
  import Ecto.Query

  alias Switchboard.{Cache, Repo, TimeZones}
  alias Switchboard.Accounts.User
  alias Switchboard.Audit.Event
  alias Switchboard.Connections.Connection

  @ttl :timer.seconds(60)
  @periods [:launch, :d30, :d7]
  @top 10

  def periods, do: @periods

  @doc """
  The stats for a period, `exclude` (user ids) and time zone; cached for a minute. Returns a
  map (see `compute/3`), with `:computed_at`.
  """
  def get(period, exclude \\ [], tz \\ "Etc/UTC") when period in @periods do
    tz = if TimeZones.valid?(tz), do: tz, else: "Etc/UTC"
    exclude = exclude |> Enum.uniq() |> Enum.sort()

    if Application.get_env(:switchboard, __MODULE__, [])[:cache] == false do
      compute(period, exclude, tz)
    else
      {:ok, stats} =
        Cache.fetch({:admin_stats, period, exclude, tz}, @ttl, fn ->
          {:ok, compute(period, exclude, tz)}
        end)

      stats
    end
  end

  @doc "The same, never cached (tests, and the cache's fill)."
  def compute(period, exclude, tz) do
    now = DateTime.utc_now()
    {from, prev_from} = window(period, now, tz)

    if is_nil(from) do
      empty(period, now)
    else
      days = days(from, now, tz)
      cross = cross_actions()
      writes = write_actions()

      # Independent scans, run side by side (each is one pass over the period's rows).
      sections = [
        headline: fn -> headline(from, now, prev_from, exclude, writes, cross) end,
        daily: fn -> daily(from, now, tz, exclude, days) end,
        tools: fn -> tools(from, now, exclude) end,
        people: fn -> people(from, now, tz, exclude) end,
        clients: fn -> clients(from, now, exclude) end,
        systems: fn -> systems(from, now, exclude) end,
        cross: fn -> cross(from, now, exclude, cross) end,
        errors: fn -> errors(from, now, exclude) end,
        connections: fn -> connections(from, prev_from, exclude) end,
        writes_by_tool: fn -> writes_by_tool(from, now, exclude, writes) end
      ]

      results =
        sections
        |> Task.async_stream(fn {key, fun} -> {key, fun.()} end,
          max_concurrency: 5,
          timeout: 30_000,
          ordered: false
        )
        |> Map.new(fn {:ok, pair} -> pair end)

      Map.merge(results, %{
        period: period,
        computed_at: now,
        from: from,
        to: now,
        days: days,
        compare?: not is_nil(prev_from)
      })
    end
  end

  defp empty(period, now) do
    %{
      period: period,
      computed_at: now,
      from: nil,
      to: now,
      days: [],
      compare?: false,
      headline: nil,
      daily: [],
      tools: [],
      people: [],
      clients: [],
      systems: [],
      cross: %{rows: [], calls: 0, share: nil},
      errors: [],
      connections: %{total: 0, by_system: [], new: 0, prev_new: nil},
      writes_by_tool: []
    }
  end

  ## Periods

  @doc "When Switchboard was first used: the first audit row (`nil` when there is none)."
  def launched_at do
    Repo.one(from e in Event, select: min(e.at))
  end

  # {from, previous from} as UTC DateTimes; days start at the viewer's midnight.
  defp window(:launch, _now, tz) do
    case launched_at() do
      nil -> {nil, nil}
      at -> {at |> local_date(tz) |> midnight(tz), nil}
    end
  end

  defp window(period, now, tz) do
    n = if period == :d30, do: 30, else: 7
    today = local_date(now, tz)
    from = today |> Date.add(-(n - 1)) |> midnight(tz)
    prev = today |> Date.add(-(2 * n - 1)) |> midnight(tz)
    {from, prev}
  end

  defp local_date(%DateTime{} = dt, tz), do: dt |> TimeZones.shift(tz) |> DateTime.to_date()

  defp midnight(date, tz) do
    case DateTime.new(date, ~T[00:00:00], tz) do
      {:ok, dt} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:ambiguous, dt, _} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:gap, _, dt} -> DateTime.shift_zone!(dt, "Etc/UTC")
      _ -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end
  end

  defp days(from, to, tz) do
    Date.range(local_date(from, tz), local_date(to, tz)) |> Enum.to_list()
  end

  ## Which actions count as what (from the tool registry)

  @doc """
  Actions that changed something in another system on someone's behalf: the write tools
  (comments, state changes, messages, drafts, error triage, notify_me), not the watch tools.
  """
  def write_actions do
    for mod <- Switchboard.Tools.all(),
        not mod.annotations()[:read_only],
        not watch_tool?(mod.name()),
        do: mod.name()
  end

  defp watch_tool?(name), do: String.starts_with?(name, "watch_") or name == "cancel_watch"

  @doc """
  Cross-system calls: the join tools (reading two or more systems; Forgejo and GitHub are one
  system here, the place a repo lives) and every workflow.
  """
  def cross_actions do
    joins =
      for mod <- Switchboard.Tools.all(),
          mod.name() != "workflow",
          length(
            Enum.uniq(Enum.map(mod.connections(), &if(&1 == :github, do: :forgejo, else: &1)))
          ) > 1,
          do: mod.name()

    joins ++ Enum.map(Switchboard.Workflows.all(), &"workflow:#{&1.name()}")
  end

  ## Queries

  defp mcp(from, to, exclude) do
    q = from(e in Event, where: e.kind == "mcp" and e.at >= ^from and e.at < ^to)

    if exclude == [],
      do: q,
      else: where(q, [e], is_nil(e.user_id) or e.user_id not in ^exclude)
  end

  defp headline(from, to, prev_from, exclude, writes, cross) do
    start = prev_from || from

    row =
      mcp(start, to, exclude)
      |> select([e], %{
        calls: filter(count(), e.at >= ^from),
        ok: filter(count(), e.at >= ^from and e.outcome == "ok"),
        people: filter(count(e.user_id, :distinct), e.at >= ^from),
        writes: filter(count(), e.at >= ^from and e.outcome == "ok" and e.action in ^writes),
        cross: filter(count(), e.at >= ^from and e.action in ^cross),
        prev_calls: filter(count(), e.at < ^from),
        prev_ok: filter(count(), e.at < ^from and e.outcome == "ok"),
        prev_people: filter(count(e.user_id, :distinct), e.at < ^from),
        prev_writes: filter(count(), e.at < ^from and e.outcome == "ok" and e.action in ^writes)
      })
      |> Repo.one()

    signups = signups(from, to, exclude)
    prev_signups = prev_from && signups(prev_from, from, exclude)
    total_people = signups(nil, to, exclude)

    %{
      signups: signups,
      prev_signups: prev_signups,
      people_total: total_people,
      active: row.people,
      prev_active: prev_from && row.prev_people,
      calls: row.calls,
      prev_calls: prev_from && row.prev_calls,
      success: ratio(row.ok, row.calls),
      prev_success: prev_from && ratio(row.prev_ok, row.prev_calls),
      writes: row.writes,
      prev_writes: prev_from && row.prev_writes,
      cross: row.cross
    }
  end

  defp ratio(_n, 0), do: nil
  defp ratio(n, d), do: n / d

  defp signups(from, to, exclude) do
    q = from(u in User, where: u.inserted_at <= ^DateTime.truncate(to, :second))
    q = if from, do: where(q, [u], u.inserted_at >= ^DateTime.truncate(from, :second)), else: q
    q = if exclude == [], do: q, else: where(q, [u], u.id not in ^exclude)
    Repo.aggregate(q, :count)
  end

  defp daily(from, to, tz, exclude, days) do
    # GROUP BY 1: the day expression has a parameter, so it can't be repeated.
    rows =
      mcp(from, to, exclude)
      |> select([e], {
        fragment("(? AT TIME ZONE 'UTC' AT TIME ZONE ?)::date", e.at, ^tz),
        filter(count(), e.outcome == "ok"),
        count(),
        count(e.user_id, :distinct)
      })
      |> group_by([e], fragment("1"))
      |> Repo.all()
      |> Map.new(fn {day, ok, calls, people} ->
        {day, %{ok: ok, calls: calls, people: people}}
      end)

    for day <- days do
      r = Map.get(rows, day, %{ok: 0, calls: 0, people: 0})
      %{day: day, ok: r.ok, error: r.calls - r.ok, people: r.people}
    end
  end

  defp tools(from, to, exclude) do
    top =
      mcp(from, to, exclude)
      |> group_by([e], e.action)
      |> select([e], %{action: e.action, calls: count(), ok: filter(count(), e.outcome == "ok")})
      |> order_by([e], desc: count(), asc: e.action)
      |> limit(@top)
      |> Repo.all()

    medians = medians(from, to, exclude, Enum.map(top, & &1.action))

    Enum.map(top, fn t ->
      t |> Map.put(:success, ratio(t.ok, t.calls)) |> Map.put(:median_ms, medians[t.action])
    end)
  end

  # Exact medians from a histogram (count per tool and duration in ms): a hash aggregate is far
  # cheaper than percentile_cont's per-group sort over a million rows.
  defp medians(_from, _to, _exclude, []), do: %{}

  defp medians(from, to, exclude, actions) do
    mcp(from, to, exclude)
    |> where([e], e.action in ^actions and not is_nil(e.duration_ms))
    |> group_by([e], [e.action, e.duration_ms])
    |> select([e], {e.action, e.duration_ms, count()})
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &{elem(&1, 1), elem(&1, 2)})
    |> Map.new(fn {action, histogram} -> {action, median(histogram)} end)
  end

  @doc false
  def median(histogram) do
    sorted = Enum.sort(histogram)
    n = sorted |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    if n == 0 do
      nil
    else
      # The values at positions ⌊(n-1)/2⌋ and ⌈(n-1)/2⌉ (0-based), averaged (percentile_cont).
      lo = nth(sorted, div(n - 1, 2))
      hi = nth(sorted, div(n, 2))
      (lo + hi) / 2
    end
  end

  defp nth([{value, count} | rest], i), do: if(i < count, do: value, else: nth(rest, i - count))

  defp people(from, to, tz, exclude) do
    mcp(from, to, exclude)
    |> where([e], not is_nil(e.user_id))
    |> group_by([e], e.user_id)
    |> select([e], %{
      user_id: e.user_id,
      username: max(e.username),
      calls: count(),
      days: fragment("count(DISTINCT (? AT TIME ZONE 'UTC' AT TIME ZONE ?)::date)", e.at, ^tz),
      last_seen: max(e.at),
      client:
        fragment("mode() WITHIN GROUP (ORDER BY coalesce(?, ?))", e.client_name, e.client_id)
    })
    |> order_by([e], desc: count(), asc: max(e.username))
    |> limit(@top)
    |> Repo.all()
    |> Enum.map(&%{&1 | client: client_label(&1.client)})
  end

  defp clients(from, to, exclude) do
    mcp(from, to, exclude)
    |> group_by([e], [e.client_id, e.client_name, e.user_id])
    |> select([e], {e.client_id, e.client_name, e.user_id, count()})
    |> Repo.all()
    |> Enum.group_by(fn {id, name, _u, _n} -> client_label("#{id} #{name}") end)
    |> Enum.map(fn {label, rows} ->
      %{
        client: label,
        calls: rows |> Enum.map(&elem(&1, 3)) |> Enum.sum(),
        people:
          rows |> Enum.map(&elem(&1, 2)) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length()
      }
    end)
    |> Enum.sort_by(&{-&1.calls, &1.client})
    |> Enum.take(@top)
  end

  @doc "A client's display group: Codex, Claude Code, or the name it gave (personal tokens)."
  def client_label(nil), do: "Unknown"

  def client_label(text) do
    down = String.downcase(text)

    cond do
      down =~ "claude" -> "Claude Code"
      down =~ "codex" or down =~ "chatgpt.com" -> "Codex"
      String.trim(text) == "" -> "Unknown"
      true -> text |> String.trim() |> String.split(" ") |> List.last() |> String.slice(0, 40)
    end
  end

  defp systems(from, to, exclude) do
    sub =
      mcp(from, to, exclude)
      |> select([e], %{system: fragment("unnest(?)", e.upstreams)})

    from(s in subquery(sub),
      group_by: s.system,
      select: %{system: s.system, calls: count()},
      order_by: [desc: count(), asc: s.system],
      limit: @top
    )
    |> Repo.all()
  end

  defp cross(from, to, exclude, actions) do
    rows =
      mcp(from, to, exclude)
      |> where([e], e.action in ^actions)
      |> group_by([e], e.action)
      |> select([e], %{action: e.action, calls: count(), ok: filter(count(), e.outcome == "ok")})
      |> order_by([e], desc: count(), asc: e.action)
      |> Repo.all()

    total = Repo.aggregate(mcp(from, to, exclude), :count)
    calls = rows |> Enum.map(& &1.calls) |> Enum.sum()

    %{
      rows: rows |> Enum.take(@top) |> Enum.map(&Map.put(&1, :share, ratio(&1.calls, total))),
      calls: calls,
      share: ratio(calls, total)
    }
  end

  # Error text without what makes each one unique: UUIDs, commit SHAs, numbers, task ids,
  # quoted values and URLs. First 160 characters, so a long upstream message groups too.
  defp errors(from, to, exclude) do
    sub =
      mcp(from, to, exclude)
      |> where([e], e.outcome != "ok" and not is_nil(e.error))
      |> select([e], %{
        action: e.action,
        reason:
          fragment(
            """
            regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
              left(split_part(?, E'\\n', 1), 160),
              '(http|https)://[^ )]+', '<url>', 'g'),
              '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<id>', 'g'),
              '\\m[0-9a-fA-F]{7,40}\\M', '<sha>', 'g'),
              '\\m[A-Za-z][A-Za-z0-9]{0,11}-[0-9]+\\M', '<task>', 'g'),
              '"[^"]*"', '"…"', 'g'),
              '[0-9]+', 'N', 'g')
            """,
            e.error
          )
      })

    from(r in subquery(sub),
      group_by: [r.action, r.reason],
      select: %{action: r.action, reason: r.reason, count: count()},
      order_by: [desc: count(), asc: r.action],
      limit: @top
    )
    |> Repo.all()
  end

  defp connections(from, prev_from, exclude) do
    q =
      from(c in Connection,
        where: c.system != "forgejo" and c.status in ["ok", "untested"],
        select: %{system: c.system, inserted_at: c.inserted_at}
      )

    q = if exclude == [], do: q, else: where(q, [c], c.user_id not in ^exclude)
    rows = Repo.all(q)
    from_s = DateTime.truncate(from, :second)

    by_system =
      rows
      |> Enum.frequencies_by(& &1.system)
      |> Enum.sort_by(fn {system, n} -> {-n, system} end)

    new = Enum.count(rows, &(DateTime.compare(&1.inserted_at, from_s) != :lt))

    prev_new =
      prev_from &&
        Enum.count(rows, fn r ->
          DateTime.compare(r.inserted_at, DateTime.truncate(prev_from, :second)) != :lt and
            DateTime.compare(r.inserted_at, from_s) == :lt
        end)

    %{total: length(rows), by_system: by_system, new: new, prev_new: prev_new}
  end

  defp writes_by_tool(from, to, exclude, writes) do
    mcp(from, to, exclude)
    |> where([e], e.outcome == "ok" and e.action in ^writes)
    |> group_by([e], e.action)
    |> select([e], {e.action, count()})
    |> order_by([e], desc: count(), asc: e.action)
    |> Repo.all()
  end
end
