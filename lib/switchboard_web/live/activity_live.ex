defmodule SwitchboardWeb.ActivityLive do
  @moduledoc "My activity: the person's own audit log (tool calls and web actions)."
  use SwitchboardWeb, :live_view

  import SwitchboardWeb.AuditComponents

  alias Switchboard.Audit

  @page 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("My activity"))
     |> assign(:filters, %{"kind" => "", "outcome" => ""})
     |> load(reset: true)}
  end

  defp load(socket, opts) do
    filters = socket.assigns.filters

    cursor =
      if opts[:reset], do: nil, else: socket.assigns[:cursor]

    events =
      Audit.list_mine(
        socket.assigns.current_scope,
        %{kind: filters["kind"], outcome: filters["outcome"], before: cursor},
        limit: @page
      )

    socket
    |> stream(:events, events, reset: opts[:reset] || false)
    |> assign(:cursor, cursor_of(List.last(events)) || cursor)
    |> assign(:more?, length(events) == @page)
  end

  defp cursor_of(nil), do: nil
  defp cursor_of(event), do: {event.at, event.id}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:activity}>
      <:crumb>{gettext("My activity")}</:crumb>
      <Layouts.page_header
        title={gettext("My activity")}
        lead={
          gettext(
            "Every tool your agents called through Switchboard, and what you changed here. Secrets are never stored."
          )
        }
      />

      <.form
        for={to_form(@filters, as: :filters)}
        id="activity-filters"
        phx-change="filter"
        class="mb-4 flex flex-wrap gap-3"
      >
        <.input
          type="select"
          name="filters[kind]"
          value={@filters["kind"]}
          options={[
            {gettext("Everything"), ""},
            {gettext("Tool calls"), "mcp"},
            {gettext("Web"), "web"}
          ]}
        />
        <.input
          type="select"
          name="filters[outcome]"
          value={@filters["outcome"]}
          options={[
            {gettext("Any outcome"), ""}
            | Enum.map(Audit.outcomes(), &{SwitchboardWeb.AuditLabels.outcome(&1), &1})
          ]}
        />
      </.form>

      <.audit_list id="activity" events={@streams.events} scope={@current_scope}>
        <:empty>
          <.empty_state icon="hero-queue-list" title={gettext("Nothing here yet")}>
            {gettext(
              "Once your agent calls Switchboard, every call shows up here. Get started shows how to connect it and what to try first."
            )}
            <:actions>
              <.button id="activity-start" size="sm" variant="primary" navigate={~p"/start"}>
                {gettext("Get started")}
              </.button>
            </:actions>
          </.empty_state>
        </:empty>
      </.audit_list>

      <div :if={@more?} class="mt-4 flex justify-center">
        <.button id="load-more" phx-click="more">{gettext("Load more")}</.button>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply,
     socket |> assign(:filters, Map.take(filters, ["kind", "outcome"])) |> load(reset: true)}
  end

  def handle_event("more", _params, socket), do: {:noreply, load(socket, [])}
end
