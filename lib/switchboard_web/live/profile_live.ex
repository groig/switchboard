defmodule SwitchboardWeb.ProfileLive do
  @moduledoc "Profile: language, time zone and theme. Identity comes from Forgejo and is read-only."
  use SwitchboardWeb, :live_view

  alias Switchboard.Accounts
  alias Switchboard.Accounts.User
  alias Switchboard.TimeZones

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     socket
     |> assign(:page_title, gettext("Profile"))
     |> assign(:form, to_form(Accounts.change_profile(user)))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:profile}>
      <:crumb>{gettext("Profile")}</:crumb>
      <Layouts.page_header title={gettext("Profile")} />

      <div class="grid gap-6 lg:grid-cols-[1fr_20rem]">
        <.card title={gettext("Preferences")} id="preferences">
          <.form
            for={@form}
            id="profile-form"
            phx-change="validate"
            phx-submit="save"
            class="space-y-4"
          >
            <.input
              field={@form[:locale]}
              type="select"
              label={gettext("Language")}
              hint={gettext("Used here and for the messages Switchboard sends you.")}
              options={[{"Español", "es"}, {"English", "en"}]}
            />
            <.input
              field={@form[:time_zone]}
              type="select"
              label={gettext("Time zone")}
              options={zone_options(@current_scope.user)}
            />
            <.input
              field={@form[:theme]}
              type="select"
              label={gettext("Theme")}
              options={[
                {gettext("System"), "system"},
                {gettext("Light"), "light"},
                {gettext("Dark"), "dark"}
              ]}
            />
            <div class="flex justify-end">
              <.button type="submit" variant="primary" id="profile-save">{gettext("Save")}</.button>
            </div>
          </.form>
        </.card>

        <.card title={gettext("Forgejo account")} id="identity">
          <div class="flex items-center gap-3">
            <.avatar
              name={User.display_name(@current_scope.user)}
              color={User.avatar_color(@current_scope.user)}
              size="lg"
            />
            <div class="min-w-0">
              <div class="truncate font-medium text-fg">{User.display_name(@current_scope.user)}</div>
              <div class="truncate text-sm text-fg-muted">@{@current_scope.user.username}</div>
              <div class="truncate text-sm text-fg-subtle">{@current_scope.user.email}</div>
            </div>
          </div>
          <p class="mt-4 text-sm text-fg-subtle">
            {gettext("Your name and email come from Forgejo. Change them there.")}
          </p>
          <.badge :if={@current_scope.user.admin} tone="accent" class="mt-3">
            {gettext("Administrator")}
          </.badge>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp zone_options(user) do
    zones = TimeZones.all()
    if user.time_zone in zones, do: zones, else: [user.time_zone | zones]
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      socket.assigns.current_scope.user
      |> Accounts.change_profile(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"user" => params}, socket) do
    scope = socket.assigns.current_scope

    case Accounts.update_profile(scope, params) do
      {:ok, user} ->
        Gettext.put_locale(SwitchboardWeb.Gettext, user.locale)

        {:noreply,
         socket
         |> assign(:current_scope, %{scope | user: user})
         |> assign(:form, to_form(Accounts.change_profile(user)))
         |> push_event("set-theme", %{theme: user.theme})
         |> put_flash(:info, gettext("Profile saved."))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end
end
