defmodule SwitchboardWeb.Admin.StatsLive do
  @moduledoc """
  Admin: usage at a glance (`Switchboard.Stats`), laid out to fit one 16:9 screen (1440×810)
  for a slide. Period, excluded people and anonymized names live in the URL, so a view can be
  reopened as it was. Charts are server-rendered SVG.
  """
  use SwitchboardWeb, :live_view

  alias Switchboard.{Accounts, Stats}

  @periods %{"launch" => :launch, "30d" => :d30, "7d" => :d7}

  @impl true
  def mount(_params, _session, socket) do
    users =
      Accounts.list_users()
      |> Enum.sort_by(&String.downcase(&1.username))
      |> Enum.map(&%{id: &1.id, username: &1.username, name: &1.name})

    {:ok, socket |> assign(:page_title, gettext("Usage")) |> assign(:users, users)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    period = Map.get(@periods, params["period"], :launch)
    known = MapSet.new(socket.assigns.users, & &1.id)

    exclude =
      (params["exclude"] || "")
      |> String.split(",", trim: true)
      |> Enum.filter(&MapSet.member?(known, &1))

    anon? = params["anon"] == "1"
    stats = Stats.get(period, exclude, socket.assigns.current_scope.user.time_zone)

    {:noreply,
     socket
     |> assign(period: period, exclude: exclude, anon?: anon?, stats: stats)
     |> assign(:names, names(stats.people, anon?))}
  end

  # Anonymized: "User 1" is the most active person in the period.
  defp names(people, true),
    do:
      people
      |> Enum.with_index(1)
      |> Map.new(fn {p, i} -> {p.user_id, gettext("User %{n}", n: i)} end)

  defp names(people, false), do: Map.new(people, &{&1.user_id, "@" <> (&1.username || "?")})

  defp stats_path(assigns, changes) do
    period = Keyword.get(changes, :period, assigns.period)
    exclude = Keyword.get(changes, :exclude, assigns.exclude)
    anon? = Keyword.get(changes, :anon?, assigns.anon?)
    key = @periods |> Enum.find(fn {_k, v} -> v == period end) |> elem(0)

    query =
      [
        {"period", key},
        exclude != [] && {"exclude", Enum.join(exclude, ",")},
        anon? && {"anon", "1"}
      ]
      |> Enum.filter(& &1)

    ~p"/admin/stats" <> "?" <> URI.encode_query(query)
  end

  @impl true
  def handle_event("anon", params, socket) do
    anon? = params["anon"] == "true"
    {:noreply, push_patch(socket, to: stats_path(socket.assigns, anon?: anon?))}
  end

  def handle_event("exclude", params, socket) do
    ids = for {id, "true"} <- Map.get(params, "people", %{}), do: id
    {:noreply, push_patch(socket, to: stats_path(socket.assigns, exclude: ids))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:admin_stats} width="full">
      <:crumb>{gettext("Admin")}</:crumb>
      <:crumb>{gettext("Usage")}</:crumb>

      <div id="stats" class="mx-auto flex max-w-[84rem] flex-col gap-2 sm:-my-5">
        <Layouts.page_header title={gettext("Usage")} size="compact">
          <:subtitle>
            <span id="stats-as-of">
              {gettext("Data as of %{when}",
                when: Format.datetime(@stats.computed_at, @current_scope)
              )}
            </span>
            <span :if={@stats.from} class="text-fg-subtle">
              · {gettext("from %{date}", date: Format.date(@stats.from, @current_scope))}
            </span>
          </:subtitle>
          <:actions>
            <.segmented id="stats-period">
              <:item
                patch={stats_path(assigns, period: :launch)}
                active={@period == :launch}
                label={gettext("Since launch")}
              />
              <:item
                patch={stats_path(assigns, period: :d30)}
                active={@period == :d30}
                label={gettext("Last 30 days")}
              />
              <:item
                patch={stats_path(assigns, period: :d7)}
                active={@period == :d7}
                label={gettext("Last 7 days")}
              />
            </.segmented>
            <.button
              id="stats-exclude-open"
              size="sm"
              icon="hero-user-minus-mini"
              phx-click={open_dialog("stats-exclude")}
            >
              <%= if @exclude == [] do %>
                {gettext("Exclude people")}
              <% else %>
                {ngettext("Excluding %{count} person", "Excluding %{count} people", length(@exclude))}
              <% end %>
            </.button>
            <.form for={%{}} as={:stats_anon} id="stats-anon" phx-change="anon">
              <.input
                type="switch"
                id="stats-anon-switch"
                name="anon"
                value={@anon?}
                label={gettext("Anonymize")}
              />
            </.form>
          </:actions>
        </Layouts.page_header>

        <%= if @stats.headline do %>
          <.tiles stats={@stats} scope={@current_scope} />

          <div class="grid gap-2 lg:grid-cols-2">
            <.chart_card
              id="chart-calls"
              title={gettext("Tool calls per day")}
              legend={[{"fill-success", gettext("OK")}, {"fill-danger", gettext("Error")}]}
              days={@stats.days}
              scope={@current_scope}
            >
              <.bar_chart daily={@stats.daily} scope={@current_scope} />
            </.chart_card>
            <.chart_card
              id="chart-people"
              title={gettext("Active people per day")}
              legend={[{"fill-accent", gettext("People with at least one call")}]}
              days={@stats.days}
              scope={@current_scope}
            >
              <.people_chart daily={@stats.daily} scope={@current_scope} />
            </.chart_card>
          </div>

          <div class="grid gap-2 lg:grid-cols-12">
            <.mini_table
              id="top-tools"
              class="lg:col-span-4"
              title={gettext("Most used tools")}
              widths={["w-[40%]"]}
              cols={[gettext("Tool"), gettext("Calls"), gettext("OK"), gettext("Median")]}
              rows={
                for t <- @stats.tools,
                    do: [
                      {:code, t.action},
                      Format.number(t.calls),
                      pct(t.success),
                      ms(t.median_ms)
                    ]
              }
            />
            <.mini_table
              id="top-people"
              class="lg:col-span-5"
              title={gettext("Most active people")}
              widths={["w-[19%]", "w-[13%]", "w-[11%]", "w-[22%]"]}
              cols={[
                gettext("Person"),
                gettext("Calls"),
                gettext("Days"),
                gettext("Last seen"),
                gettext("Main client")
              ]}
              rows={
                for p <- @stats.people,
                    do: [
                      @names[p.user_id],
                      Format.number(p.calls),
                      Format.number(p.days),
                      last_seen(p.last_seen, @current_scope),
                      p.client
                    ]
              }
            />
            <.mini_table
              id="top-clients"
              class="lg:col-span-3"
              title={gettext("Clients")}
              widths={["w-[46%]"]}
              cols={[gettext("Client"), gettext("Calls"), gettext("People")]}
              rows={
                for c <- @stats.clients,
                    do: [c.client, Format.number(c.calls), Format.number(c.people)]
              }
            />
            <.mini_table
              id="top-systems"
              class="lg:col-span-3"
              title={gettext("Systems touched")}
              widths={["w-[60%]"]}
              cols={[gettext("System"), gettext("Calls")]}
              rows={for s <- @stats.systems, do: [system_label(s.system), Format.number(s.calls)]}
            />
            <.mini_table
              id="top-cross"
              class="lg:col-span-4"
              title={gettext("Cross-system calls")}
              widths={["w-[46%]"]}
              note={gettext("%{share} of all calls", share: pct(@stats.cross.share))}
              cols={[gettext("Join or workflow"), gettext("Calls"), gettext("Share")]}
              rows={
                for c <- @stats.cross.rows,
                    do: [{:code, c.action}, Format.number(c.calls), pct(c.share)]
              }
            />
            <.mini_table
              id="top-errors"
              class="lg:col-span-5"
              title={gettext("Top error reasons")}
              widths={["w-[27%]", "", "w-[13%]"]}
              left={[0, 1]}
              cols={[gettext("Tool"), gettext("Reason"), gettext("Count")]}
              rows={
                for e <- @stats.errors,
                    do: [{:code, e.action}, {:wrap, e.reason}, Format.number(e.count)]
              }
            />
          </div>
        <% else %>
          <.empty_state icon="hero-chart-bar" title={gettext("No activity yet")}>
            {gettext("The numbers appear once someone makes a tool call.")}
          </.empty_state>
        <% end %>
      </div>

      <.sheet
        id="stats-exclude"
        title={gettext("Exclude people")}
        description={
          gettext(
            "Leave people out of every number on the page, e.g. whoever builds or tests Switchboard."
          )
        }
        width="24rem"
      >
        <.form for={%{}} as={:people} id="stats-exclude-form" phx-change="exclude" class="space-y-2">
          <.input
            :for={u <- @users}
            type="switch"
            id={"exclude-#{u.id}"}
            name={"people[#{u.id}]"}
            value={u.id in @exclude}
            label={"@" <> u.username}
            hint={u.name}
          />
        </.form>
      </.sheet>
    </Layouts.app>
    """
  end

  ## Tiles

  attr :stats, :map, required: true
  attr :scope, :any, required: true

  defp tiles(assigns) do
    h = assigns.stats.headline
    c = assigns.stats.connections
    compare? = assigns.stats.compare?

    systems =
      c.by_system
      |> Enum.take(5)
      |> Enum.map_join(" · ", fn {system, n} -> "#{system_label(system)} #{n}" end)

    writes =
      assigns.stats.writes_by_tool
      |> Enum.take(3)
      |> Enum.map_join(" · ", fn {action, n} -> "#{action} #{n}" end)

    assigns =
      assign(assigns,
        items: [
          %{
            id: "tile-signups",
            label: gettext("People signed up"),
            value: Format.number(h.signups),
            delta: compare? && count_delta(h.signups, h.prev_signups),
            sub:
              if(assigns.stats.period == :launch,
                do: gettext("since the first sign-in"),
                else: gettext("%{total} in total", total: Format.number(h.people_total))
              )
          },
          %{
            id: "tile-active",
            label: gettext("People active"),
            value: Format.number(h.active),
            delta: compare? && count_delta(h.active, h.prev_active),
            sub: gettext("at least one tool call")
          },
          %{
            id: "tile-calls",
            label: gettext("Tool calls"),
            value: Format.number(h.calls),
            delta: compare? && count_delta(h.calls, h.prev_calls),
            sub:
              gettext("%{n} a day on average",
                n: Format.number(per_day(h.calls, assigns.stats.days))
              )
          },
          %{
            id: "tile-success",
            label: gettext("Success rate"),
            value: pct(h.success),
            delta: compare? && points_delta(h.success, h.prev_success),
            sub: gettext("calls that answered OK")
          },
          %{
            id: "tile-connections",
            label: gettext("Systems connected"),
            value: Format.number(c.total),
            delta: compare? && count_delta(c.new, c.prev_new, gettext("new")),
            sub: if(systems == "", do: gettext("no keys linked yet"), else: systems)
          },
          %{
            id: "tile-writes",
            label: gettext("Actions taken"),
            value: Format.number(h.writes),
            delta: compare? && count_delta(h.writes, h.prev_writes),
            sub: if(writes == "", do: gettext("comments, state changes, messages"), else: writes)
          }
        ]
      )

    ~H"""
    <div id="stats-tiles" class="grid grid-cols-2 gap-2 sm:grid-cols-3 xl:grid-cols-6">
      <div
        :for={t <- @items}
        id={t.id}
        class="min-w-0 rounded-lg border border-border bg-surface px-3.5 py-1.5 shadow-xs"
      >
        <div class="truncate text-xs font-medium text-fg-muted">{t.label}</div>
        <div class="flex items-baseline gap-2">
          <span class="text-2xl font-semibold text-fg tabular-nums">{t.value}</span>
          <span
            :if={t.delta}
            class={[
              "inline-flex items-center gap-0.5 rounded-sm px-1 text-2xs font-medium tabular-nums",
              elem(t.delta, 0) == :up && "bg-success-soft text-success-fg",
              elem(t.delta, 0) == :down && "bg-danger-soft text-danger-fg",
              elem(t.delta, 0) == :flat && "bg-hover text-fg-muted"
            ]}
            title={gettext("Compared with the previous period of the same length")}
          >
            <.icon
              :if={elem(t.delta, 0) != :flat}
              name={
                if(elem(t.delta, 0) == :up, do: "hero-arrow-up-micro", else: "hero-arrow-down-micro")
              }
              class="size-3"
            />
            {elem(t.delta, 1)}
          </span>
        </div>
        <div class="truncate text-2xs text-fg-subtle" title={t.sub}>{t.sub}</div>
      </div>
    </div>
    """
  end

  defp per_day(_calls, []), do: 0
  defp per_day(calls, days), do: round(calls / length(days))

  defp count_delta(cur, prev, suffix \\ nil)
  defp count_delta(_cur, nil, _suffix), do: nil
  defp count_delta(cur, prev, _suffix) when cur == prev, do: {:flat, "±0"}

  defp count_delta(cur, 0, _suffix) when cur > 0, do: {:up, gettext("new")}

  defp count_delta(cur, prev, nil) do
    change = (cur - prev) / prev * 100
    {if(change >= 0, do: :up, else: :down), sign(change) <> Format.percent(abs(change))}
  end

  defp count_delta(cur, prev, suffix) do
    {if(cur >= prev, do: :up, else: :down), "#{cur} #{suffix}"}
  end

  defp points_delta(nil, _), do: nil
  defp points_delta(_, nil), do: nil

  defp points_delta(cur, prev) do
    diff = (cur - prev) * 100

    cond do
      abs(diff) < 0.5 -> {:flat, "±0 pp"}
      diff > 0 -> {:up, "+#{Format.number(Float.round(diff, 1))} pp"}
      true -> {:down, "−#{Format.number(Float.round(abs(diff), 1))} pp"}
    end
  end

  defp sign(change) when change >= 0, do: "+"
  defp sign(_), do: "−"

  ## Charts

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :legend, :list, required: true
  attr :days, :list, required: true
  attr :scope, :any, required: true
  slot :inner_block, required: true

  defp chart_card(assigns) do
    ~H"""
    <section id={@id} class="rounded-lg border border-border bg-surface px-3.5 pt-2 pb-1.5 shadow-xs">
      <header class="mb-1 flex items-center justify-between gap-3">
        <h2 class="text-sm font-semibold text-fg">{@title}</h2>
        <div class="flex items-center gap-3 text-2xs text-fg-muted">
          <span :for={{fill, label} <- @legend} class="flex items-center gap-1">
            <svg class="size-2" viewBox="0 0 2 2" aria-hidden="true">
              <rect width="2" height="2" rx="0.5" class={fill} />
            </svg>
            {label}
          </span>
        </div>
      </header>
      {render_slot(@inner_block)}
      <div class="mt-0.5 mr-8 flex justify-between text-2xs text-fg-subtle tabular-nums">
        <span :for={d <- axis_days(@days)}>{short_date(d)}</span>
      </div>
    </section>
    """
  end

  @chart_h 100

  attr :daily, :list, required: true
  attr :scope, :any, required: true

  defp bar_chart(assigns) do
    max = assigns.daily |> Enum.map(&(&1.ok + &1.error)) |> Enum.max(fn -> 0 end)
    n = max(length(assigns.daily), 1)
    slot = 1000 / n
    gap = min(slot * 0.25, 6)
    scale = nice_max(max)

    bars =
      assigns.daily
      |> Enum.with_index()
      |> Enum.map(fn {d, i} ->
        ok_h = bar_h(d.ok, scale)
        err_h = bar_h(d.error, scale)

        %{
          x: i * slot + gap / 2,
          w: slot - gap,
          ok_y: @chart_h - ok_h,
          ok_h: ok_h,
          err_y: @chart_h - ok_h - err_h,
          err_h: err_h,
          title: "#{short_date(d.day)}: #{d.ok} OK, #{d.error} #{gettext("errors")}"
        }
      end)

    assigns = assign(assigns, bars: bars, scale: scale, h: @chart_h)

    ~H"""
    <div class="relative mr-8">
      <.gridlines scale={@scale} />
      <svg
        viewBox={"0 0 1000 #{@h}"}
        preserveAspectRatio="none"
        class="relative block h-[4.75rem] w-full"
        role="img"
        aria-label={gettext("Tool calls per day")}
      >
        <g :for={b <- @bars}>
          <title>{b.title}</title>
          <rect :if={b.ok_h > 0} x={b.x} y={b.ok_y} width={b.w} height={b.ok_h} class="fill-success" />
          <rect
            :if={b.err_h > 0}
            x={b.x}
            y={b.err_y}
            width={b.w}
            height={b.err_h}
            class="fill-danger"
          />
        </g>
      </svg>
    </div>
    """
  end

  attr :daily, :list, required: true
  attr :scope, :any, required: true

  defp people_chart(assigns) do
    max = assigns.daily |> Enum.map(& &1.people) |> Enum.max(fn -> 0 end)
    scale = nice_max(max)
    n = length(assigns.daily)
    step = if n > 1, do: 1000 / (n - 1), else: 0

    points =
      assigns.daily
      |> Enum.with_index()
      |> Enum.map(fn {d, i} ->
        {if(n > 1, do: i * step, else: 500), @chart_h - bar_h(d.people, scale), d}
      end)

    line = Enum.map_join(points, " ", fn {x, y, _} -> "#{fmt(x)},#{fmt(y)}" end)

    area =
      case points do
        [] ->
          ""

        [{x0, _, _} | _] ->
          "M#{fmt(x0)},#{@chart_h} L" <>
            String.replace(line, " ", " L") <>
            " L#{fmt(elem(List.last(points), 0))},#{@chart_h} Z"
      end

    assigns = assign(assigns, scale: scale, line: line, area: area, points: points, h: @chart_h)

    ~H"""
    <div class="relative mr-8">
      <.gridlines scale={@scale} />
      <svg
        viewBox={"0 0 1000 #{@h}"}
        preserveAspectRatio="none"
        class="relative block h-[4.75rem] w-full overflow-visible"
        role="img"
        aria-label={gettext("Active people per day")}
      >
        <path :if={@area != ""} d={@area} class="fill-accent-soft" />
        <polyline
          points={@line}
          fill="none"
          class="stroke-accent"
          stroke-width="2"
          stroke-linejoin="round"
          vector-effect="non-scaling-stroke"
        />
        <rect
          :for={{x, _y, d} <- @points}
          x={x - 500 / max(length(@points), 1)}
          y="0"
          width={1000 / max(length(@points), 1)}
          height={@h}
          class="fill-transparent"
        >
          <title>
            {short_date(d.day)}: {ngettext("%{count} person", "%{count} people", d.people)}
          </title>
        </rect>
      </svg>
    </div>
    """
  end

  attr :scale, :integer, required: true

  defp gridlines(assigns) do
    ~H"""
    <div class="pointer-events-none absolute inset-0 flex flex-col justify-between" aria-hidden="true">
      <div
        :for={v <- [@scale, div(@scale, 2), 0]}
        class="relative border-t border-dashed border-border"
      >
        <span class="absolute -top-2 -right-8 w-7 text-right text-2xs leading-4 text-fg-subtle tabular-nums">
          {Format.number(v)}
        </span>
      </div>
    </div>
    """
  end

  defp bar_h(_v, 0), do: 0
  defp bar_h(v, scale), do: v / scale * (@chart_h - 6)

  # A round axis maximum (1, 2, 5 × 10ⁿ), even so its half is a whole number.
  defp nice_max(0), do: 2

  defp nice_max(max) do
    mag = :math.pow(10, floor(:math.log10(max))) |> round()
    (Enum.find([2, 4, 6, 10, 20], &(&1 * mag >= max)) * mag) |> max(2)
  end

  defp fmt(n), do: :erlang.float_to_binary(n / 1, decimals: 1)

  defp axis_days([]), do: []
  defp axis_days([d]), do: [d]

  defp axis_days(days) do
    n = length(days)
    idx = Enum.uniq([0, div(n - 1, 4), div(n - 1, 2), div(3 * (n - 1), 4), n - 1])
    Enum.map(idx, &Enum.at(days, &1))
  end

  defp short_date(%Date{} = d), do: Calendar.strftime(d, "%d/%m")

  ## Tables

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :note, :string, default: nil
  attr :cols, :list, required: true
  attr :rows, :list, required: true
  attr :widths, :list, default: [], doc: "width classes per column (the rest share the space)"
  attr :left, :list, default: [0], doc: "columns aligned left (the rest are numbers)"
  attr :class, :any, default: nil

  defp mini_table(assigns) do
    ~H"""
    <section id={@id} class={["min-w-0 rounded-lg border border-border bg-surface shadow-xs", @class]}>
      <header class="flex items-baseline justify-between gap-2 px-3 pt-1.5 pb-0.5">
        <h2 class="truncate text-sm font-semibold text-fg">{@title}</h2>
        <span :if={@note} class="shrink-0 text-2xs text-fg-muted">{@note}</span>
      </header>
      <table class="w-full table-fixed text-xs">
        <thead>
          <tr class="text-left text-2xs text-fg-subtle">
            <th
              :for={{col, i} <- Enum.with_index(@cols)}
              class={[
                "truncate px-3 pb-0.5 font-medium",
                Enum.at(@widths, i),
                i not in @left && "text-right"
              ]}
            >
              {col}
            </th>
          </tr>
        </thead>
        <tbody class="border-t border-border">
          <tr :for={row <- @rows} class="h-4 leading-4 even:bg-inset/60">
            <td
              :for={{cell, i} <- Enum.with_index(row)}
              class={[
                "truncate px-3 text-fg tabular-nums",
                i > 0 && not match?({:wrap, _}, cell) && "text-right text-fg-muted"
              ]}
              title={cell_text(cell)}
            >
              <%= case cell do %>
                <% {:code, text} -> %>
                  <span class="font-mono text-2xs text-fg">{text}</span>
                <% {:wrap, text} -> %>
                  <span class="text-fg">{text}</span>
                <% text -> %>
                  {text}
              <% end %>
            </td>
          </tr>
          <tr :if={@rows == []}>
            <td colspan={length(@cols)} class="px-3 py-2 text-fg-subtle">{gettext("Nothing yet")}</td>
          </tr>
        </tbody>
      </table>
      <div class="h-1" />
    </section>
    """
  end

  # Today: the time; earlier: the date (the column is narrow).
  defp last_seen(at, scope) do
    tz = scope.user.time_zone
    local = Switchboard.TimeZones.shift(at, tz)
    today = Switchboard.TimeZones.shift(DateTime.utc_now(), tz)

    if DateTime.to_date(local) == DateTime.to_date(today),
      do: Format.time_of_day(at, scope),
      else: Calendar.strftime(local, "%d/%m")
  end

  defp cell_text({_, text}), do: text
  defp cell_text(text), do: text

  defp pct(nil), do: "–"
  defp pct(ratio), do: Format.percent(ratio * 100)

  defp ms(nil), do: "–"
  defp ms(v) when v < 1000, do: "#{round(v)} ms"
  defp ms(v), do: "#{Format.number(Float.round(v / 1000, 1))} s"

  defp system_label(system) do
    case Switchboard.Upstreams.fetch(system) do
      {:ok, mod} -> mod.label()
      :error -> if(system == "releases", do: gettext("Releases feed"), else: system)
    end
  end
end
