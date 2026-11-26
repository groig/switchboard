defmodule SwitchboardWeb.Admin.PeopleLive do
  @moduledoc "Admin: everyone who has signed in, with their clients and tokens, and revoke-all."
  use SwitchboardWeb, :live_view

  import Ecto.Query

  alias Switchboard.Accounts
  alias Switchboard.Accounts.User
  alias Switchboard.OAuth.Grant
  alias Switchboard.PersonalTokens.PersonalToken
  alias Switchboard.Repo
  alias SwitchboardWeb.UserAuth

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, gettext("People")) |> load()}
  end

  defp load(socket) do
    assign(socket, users: Accounts.list_users(), counts: counts())
  end

  # Active grants and personal tokens per person, in two queries.
  defp counts do
    grants =
      from(g in Grant,
        where: is_nil(g.revoked_at),
        group_by: g.user_id,
        select: {g.user_id, count()}
      )
      |> Repo.all()
      |> Map.new()

    tokens =
      from(t in PersonalToken,
        where: is_nil(t.revoked_at),
        group_by: t.user_id,
        select: {t.user_id, count()}
      )
      |> Repo.all()
      |> Map.new()

    %{grants: grants, tokens: tokens, watches: Switchboard.Watches.active_counts()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:admin_people}>
      <:crumb>{gettext("Admin")}</:crumb>
      <:crumb>{gettext("People")}</:crumb>
      <Layouts.page_header
        title={gettext("People")}
        lead={
          gettext(
            "Revoke all disconnects every client, revokes personal tokens and signs the person out of the web app. Their linked keys stay."
          )
        }
      />

      <.table id="people" rows={@users} row_id={&"user-#{&1.id}"}>
        <:col :let={user} label={gettext("Person")}>
          <div class="flex items-center gap-2.5">
            <.avatar name={User.display_name(user)} color={User.avatar_color(user)} size="sm" />
            <div class="min-w-0">
              <div class="truncate font-medium text-fg">
                {User.display_name(user)}
                <.badge :if={user.admin} tone="accent" class="ml-1">{gettext("admin")}</.badge>
              </div>
              <div class="truncate text-xs text-fg-subtle">@{user.username} · {user.email}</div>
            </div>
          </div>
        </:col>
        <:col :let={user} label={gettext("Clients")} numeric>
          {Map.get(@counts.grants, user.id, 0)}
        </:col>
        <:col :let={user} label={gettext("Tokens")} numeric>
          {Map.get(@counts.tokens, user.id, 0)}
        </:col>
        <:col :let={user} label={gettext("Active watches")} numeric>
          {Map.get(@counts.watches, user.id, 0)}
        </:col>
        <:col :let={user} label={gettext("Last sign-in")}>
          <.relative_time at={user.last_login_at} scope={@current_scope} />
        </:col>
        <:action :let={user}>
          <.button
            id={"revoke-all-#{user.id}"}
            size="sm"
            variant="danger"
            phx-click="revoke_all"
            phx-value-id={user.id}
            data-confirm={gettext("Revoke everything for %{name}?", name: user.username)}
          >
            {gettext("Revoke all")}
          </.button>
        </:action>
      </.table>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("revoke_all", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)
    :ok = Accounts.revoke_all(socket.assigns.current_scope, user)
    UserAuth.disconnect_sessions(user)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Revoked everything for %{name}.", name: user.username))
     |> load()}
  end
end
