defmodule SwitchboardWeb.Admin.HealthLive do
  @moduledoc "Admin: is each upstream reachable from Switchboard, and how fast."
  use SwitchboardWeb, :live_view

  alias Switchboard.Upstreams

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, page_title: gettext("Upstream health"), breakers: %{})
    {:ok, if(connected?(socket), do: check(socket), else: assign(socket, :results, nil))}
  end

  defp check(socket) do
    socket
    |> assign(:results, nil)
    |> start_async(:health, fn -> Upstreams.health() end)
  end

  @impl true
  def handle_async(:health, {:ok, results}, socket),
    do:
      {:noreply, assign(socket, results: results, breakers: Switchboard.Upstreams.Guard.status())}

  def handle_async(:health, _, socket), do: {:noreply, assign(socket, :results, [])}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:admin_health}>
      <:crumb>{gettext("Admin")}</:crumb>
      <:crumb>{gettext("Upstream health")}</:crumb>
      <:actions>
        <.button
          id="recheck"
          size="sm"
          icon="hero-arrow-path-mini"
          loading={is_nil(@results)}
          phx-click="recheck"
        >
          {gettext("Check again")}
        </.button>
      </:actions>
      <Layouts.page_header
        title={gettext("Upstream health")}
        lead={
          gettext(
            "A plain request to each system from the server. Any answer below 500 counts as up."
          )
        }
      />

      <div id="health" class="grid gap-3 sm:grid-cols-2">
        <%= if @results do %>
          <div
            :for={r <- @results}
            id={"health-#{r.system}"}
            class="flex items-center gap-3 rounded-xl border border-border bg-surface p-4 shadow-xs"
          >
            <span class={[
              "size-2.5 shrink-0 rounded-full",
              if(r.status == :up, do: "bg-success", else: "bg-danger")
            ]} />
            <div class="min-w-0 flex-1">
              <div class="flex items-center gap-2 font-medium text-fg">
                {r.label}
                <%= case @breakers[String.to_existing_atom(r.system)] do %>
                  <% :open -> %>
                    <.badge tone="danger" id={"breaker-#{r.system}"}>
                      {gettext("Breaker open")}
                    </.badge>
                  <% :half_open -> %>
                    <.badge tone="warning" id={"breaker-#{r.system}"}>{gettext("Recovering")}</.badge>
                  <% _ -> %>
                <% end %>
              </div>
              <div class="truncate font-mono text-2xs text-fg-subtle">{r.url}</div>
            </div>
            <div class="text-right text-xs">
              <div class={if(r.status == :up, do: "text-success-fg", else: "text-danger-fg")}>
                {if(r.status == :up, do: gettext("Up"), else: gettext("Down"))}
              </div>
              <div class="text-fg-subtle tabular-nums">
                {r.detail}<span :if={r.ms}> · {r.ms} ms</span>
              </div>
            </div>
          </div>
        <% else %>
          <div
            :for={i <- 1..5}
            id={"health-skeleton-#{i}"}
            class="rounded-xl border border-border bg-surface p-4"
          >
            <.skeleton class="h-4 w-24" />
            <.skeleton class="mt-2 h-3 w-48" />
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("recheck", _params, socket), do: {:noreply, check(socket)}
end
