defmodule SwitchboardWeb.Admin.AuditLive do
  @moduledoc "Admin: everyone's audit log, filterable by person, kind, action and outcome."
  use SwitchboardWeb, :live_view

  import SwitchboardWeb.AuditComponents

  alias Switchboard.Audit
  alias SwitchboardWeb.AuditLabels

  @page 50
  @filter_keys ~w(username kind action outcome)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Audit log"))
     |> assign(:actions, Audit.actions())
     |> assign(:usernames, Enum.map(Switchboard.Accounts.list_users(), & &1.username))
     |> assign(:retention, Audit.retention_days())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = Map.new(@filter_keys, &{&1, params[&1] || ""})
    {:noreply, socket |> assign(:filters, filters) |> load(reset: true)}
  end

  defp load(socket, opts) do
    f = socket.assigns.filters
    cursor = if opts[:reset], do: nil, else: socket.assigns[:cursor]

    events =
      Audit.list(
        %{
          username: f["username"],
          kind: f["kind"],
          action: f["action"],
          outcome: f["outcome"],
          before: cursor
        },
        limit: @page
      )

    socket
    |> stream(:events, events, reset: opts[:reset] || false)
    |> assign(
      :cursor,
      if(events == [], do: cursor, else: {List.last(events).at, List.last(events).id})
    )
    |> assign(:more?, length(events) == @page)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:admin_audit} width="wide">
      <:crumb>{gettext("Admin")}</:crumb>
      <:crumb>{gettext("Audit log")}</:crumb>
      <Layouts.page_header
        title={gettext("Audit log")}
        lead={gettext("Append-only. Rows older than %{days} days are deleted.", days: @retention)}
      />

      <.form
        for={to_form(@filters, as: :f)}
        id="audit-filters"
        phx-change="filter"
        class="mb-4 flex flex-wrap gap-3"
      >
        <.input
          type="select"
          name="f[username]"
          value={@filters["username"]}
          options={[{gettext("Everyone"), ""} | @usernames]}
        />
        <.input
          type="select"
          name="f[kind]"
          value={@filters["kind"]}
          options={[
            {gettext("Everything"), ""},
            {gettext("Tool calls"), "mcp"},
            {gettext("Web"), "web"}
          ]}
        />
        <.input
          type="select"
          name="f[action]"
          value={@filters["action"]}
          options={[{gettext("Any action"), ""} | Enum.map(@actions, &{AuditLabels.action(&1), &1})]}
        />
        <.input
          type="select"
          name="f[outcome]"
          value={@filters["outcome"]}
          options={[
            {gettext("Any outcome"), ""} | Enum.map(Audit.outcomes(), &{AuditLabels.outcome(&1), &1})
          ]}
        />
      </.form>

      <.audit_list id="audit" events={@streams.events} scope={@current_scope} show_user />

      <div :if={@more?} class="mt-4 flex justify-center">
        <.button id="load-more" phx-click="more">{gettext("Load more")}</.button>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("filter", %{"f" => f}, socket) do
    query = f |> Map.take(@filter_keys) |> Map.reject(fn {_k, v} -> v == "" end)
    {:noreply, push_patch(socket, to: ~p"/admin/audit?#{query}")}
  end

  def handle_event("more", _params, socket), do: {:noreply, load(socket, [])}
end
