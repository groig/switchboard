defmodule SwitchboardWeb.ConnectionsLive do
  @moduledoc """
  The person's upstream credentials: link a key (tested before it is stored), test it again,
  replace or remove it. GitHub is connected through its OAuth flow instead (a Connect button to
  `/auth/github`) and disconnecting revokes the grant. Secrets never reach the socket: the page
  only sees status and identity.
  """
  use SwitchboardWeb, :live_view

  alias Switchboard.{Connections, Upstreams}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Connections"))
     |> assign(:linking, nil)
     |> assign(:link_error, nil)
     |> assign(:testing, MapSet.new())
     |> load()}
  end

  defp load(socket) do
    assign(socket, :connections, Connections.list(socket.assigns.current_scope))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:connections}>
      <:crumb>{gettext("Connections")}</:crumb>

      <Layouts.page_header
        title={gettext("Connections")}
        lead={
          gettext(
            "Switchboard calls each system as you, with your own keys, stored encrypted on the server. Your agent never sees them."
          )
        }
      />

      <div
        :if={Enum.all?(Map.keys(@connections), &(&1 == "forgejo"))}
        id="connections-start"
        class="mb-4 flex flex-wrap items-center gap-3 rounded-lg border border-border bg-surface px-4 py-3 text-sm text-fg shadow-xs"
      >
        <.icon name="hero-rocket-launch" class="size-4.5 shrink-0 text-fg-subtle" />
        <p class="min-w-0 flex-1">
          {gettext(
            "Nothing linked yet. Get started shows what each system unlocks and where to create its key."
          )}
        </p>
        <.button id="connections-start-link" size="sm" navigate={~p"/start"}>
          {gettext("Get started")}
        </.button>
      </div>

      <div
        id="migrate-keys"
        class="mb-6 flex gap-3 rounded-lg border border-border bg-accent-soft/60 px-4 py-3 text-sm text-fg"
      >
        <.icon name="hero-light-bulb" class="mt-0.5 size-4.5 shrink-0 text-accent-fg" />
        <p>
          {gettext(
            "Already have Plane, Rocket.Chat or wiki keys on your computer? Paste them here, then delete them from your computer and your agent's settings."
          )}
        </p>
      </div>

      <div id="connections" class="grid gap-3">
        <.system_card
          :for={mod <- Upstreams.all()}
          mod={mod}
          connection={@connections[mod.system()]}
          testing={MapSet.member?(@testing, mod.system())}
          scope={@current_scope}
        />
      </div>

      <.dialog
        :if={@linking}
        id="link-dialog"
        show
        title={gettext("Link %{system}", system: @linking.label())}
        on_close={JS.push("cancel_link")}
      >
        <.form for={@form} id="link-form" phx-submit="link" class="space-y-4">
          <p class="text-sm text-fg-muted">{@linking.permissions()}</p>
          <.link
            :if={@linking.key_url()}
            href={@linking.key_url()}
            target="_blank"
            rel="noopener noreferrer"
            class="inline-flex items-center gap-1 text-sm font-medium text-accent-fg hover:underline"
            id="key-url"
          >
            {gettext("Create a key in %{system}", system: @linking.label())}
            <.icon name="hero-arrow-top-right-on-square-micro" class="size-3.5" />
          </.link>
          <.input
            :for={field <- @linking.fields()}
            field={@form[field.name]}
            type={if(field.secret?, do: "password", else: "text")}
            label={field.label}
            autocomplete="off"
            spellcheck="false"
          />
          <p :if={@link_error} id="link-error" class="text-sm text-danger-fg">{@link_error}</p>
          <div class="flex justify-end gap-2 pt-2">
            <.button phx-click={close_dialog("link-dialog")}>{gettext("Cancel")}</.button>
            <.button type="submit" variant="primary" id="link-submit">
              {gettext("Test and save")}
            </.button>
          </div>
        </.form>
      </.dialog>
    </Layouts.app>
    """
  end

  attr :mod, :atom, required: true
  attr :connection, :any, required: true
  attr :testing, :boolean, required: true
  attr :scope, :any, required: true

  defp system_card(assigns) do
    assigns =
      assign(assigns,
        system: assigns.mod.system(),
        connect_path:
          if(function_exported?(assigns.mod, :connect_path, 0), do: assigns.mod.connect_path())
      )

    ~H"""
    <section
      id={"connection-#{@system}"}
      class={[
        "flex scroll-mt-20 flex-col gap-3 rounded-xl border border-border bg-surface p-4 shadow-xs sm:flex-row sm:items-center",
        "transition-shadow duration-(--duration-base) target:border-accent target:ring-2 target:ring-accent/25"
      ]}
    >
      <div class="flex min-w-0 flex-1 items-start gap-3">
        <div class="flex size-9 shrink-0 items-center justify-center rounded-lg bg-inset text-fg-muted">
          <.icon name={system_icon(@system)} class="size-4.5" />
        </div>
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <h2 class="text-md font-semibold text-fg">{@mod.label()}</h2>
            <.status_badge connection={@connection} />
          </div>
          <p class="mt-0.5 text-sm text-fg-muted">
            <%= cond do %>
              <% @connection && @connection.identity["email"] -> %>
                {gettext("Belongs to %{who}",
                  who: identity_label(@connection.identity)
                )}
              <% @connection && @connection.identity["username"] -> %>
                {gettext("Belongs to %{who}", who: identity_label(@connection.identity))}
              <% @connection -> %>
                {gettext("Linked")}
              <% true -> %>
                {@mod.permissions()}
            <% end %>
            <span :if={@connection && @connection.last_tested_at} class="text-fg-subtle">
              · {gettext("tested")} <.relative_time at={@connection.last_tested_at} scope={@scope} />
            </span>
          </p>
          <p
            :if={@connection && @connection.identity_matches == false}
            id={"mismatch-#{@system}"}
            class="mt-1.5 flex items-center gap-1.5 text-sm text-warning-fg"
          >
            <.icon name="hero-exclamation-triangle-mini" class="size-4" />
            {gettext("This key belongs to someone else, not to %{you}. Link your own key.",
              you: @scope.user.email || @scope.user.username
            )}
          </p>
          <p :if={@system == "github" && @connection} class="mt-1.5 text-sm text-fg-muted">
            {gettext("Repositories of an organization missing?")}
            <.link
              id="github-org-access"
              href={Switchboard.GitHub.app_settings_url()}
              target="_blank"
              rel="noopener noreferrer"
              class="inline-flex items-center gap-1 font-medium text-accent-fg hover:underline"
            >
              {gettext("Request the organization's approval in GitHub")}
              <.icon name="hero-arrow-top-right-on-square-micro" class="size-3.5" />
            </.link>
          </p>
        </div>
      </div>

      <div class="flex shrink-0 items-center gap-2">
        <%= if @connection do %>
          <.button
            id={"test-#{@system}"}
            size="sm"
            icon="hero-bolt-mini"
            loading={@testing}
            phx-click="test"
            phx-value-system={@system}
          >
            {gettext("Test")}
          </.button>
          <%= if @connect_path do %>
            <.button id={"reconnect-#{@system}"} size="sm" href={@connect_path}>
              {gettext("Reconnect")}
            </.button>
            <.icon_button
              id={"remove-#{@system}"}
              icon="hero-trash-mini"
              label={gettext("Disconnect")}
              variant="ghost"
              phx-click="unlink"
              phx-value-system={@system}
              data-confirm={
                gettext("Disconnect %{system}? Switchboard revokes its access in %{system}.",
                  system: @mod.label()
                )
              }
            />
          <% end %>
          <%= if @mod.fields() != [] do %>
            <.button
              id={"replace-#{@system}"}
              size="sm"
              phx-click="start_link"
              phx-value-system={@system}
            >
              {gettext("Replace")}
            </.button>
            <.icon_button
              id={"remove-#{@system}"}
              icon="hero-trash-mini"
              label={gettext("Remove")}
              variant="ghost"
              phx-click="unlink"
              phx-value-system={@system}
              data-confirm={
                gettext("Remove the %{system} key from Switchboard?", system: @mod.label())
              }
            />
          <% end %>
        <% else %>
          <.button
            :if={@connect_path}
            id={"connect-#{@system}"}
            size="sm"
            variant="primary"
            icon="hero-link-mini"
            href={@connect_path}
          >
            {gettext("Connect %{system}", system: @mod.label())}
          </.button>
          <.button
            :if={@mod.fields() != []}
            id={"link-#{@system}"}
            size="sm"
            variant="primary"
            icon="hero-plus-mini"
            phx-click="start_link"
            phx-value-system={@system}
          >
            {gettext("Link")}
          </.button>
        <% end %>
      </div>
    </section>
    """
  end

  attr :connection, :any, required: true

  defp status_badge(assigns) do
    ~H"""
    <%= case @connection && @connection.status do %>
      <% "ok" -> %>
        <.badge tone="success" dot>{gettext("Connected")}</.badge>
      <% "rejected" -> %>
        <.badge tone="danger" dot>{gettext("Key rejected")}</.badge>
      <% "error" -> %>
        <.badge tone="warning" dot>{gettext("Couldn't test")}</.badge>
      <% "untested" -> %>
        <.badge tone="warning" dot>{gettext("Not tested")}</.badge>
      <% _ -> %>
        <.badge>{gettext("Not connected")}</.badge>
    <% end %>
    """
  end

  defp identity_label(identity) do
    [identity["name"], identity["email"] || identity["username"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [name, handle] when name != handle -> "#{name} (#{handle})"
      [one | _] -> one
    end
  end

  @doc false
  def system_icon("forgejo"), do: "hero-code-bracket-square"
  def system_icon("plane"), do: "hero-clipboard-document-check"
  def system_icon("argus"), do: "hero-bug-ant"
  def system_icon("outline"), do: "hero-book-open"
  def system_icon("rocketchat"), do: "hero-chat-bubble-left-right"
  def system_icon("github"), do: "hero-code-bracket"

  @impl true
  def handle_event("start_link", %{"system" => system}, socket) do
    with {:ok, mod} <- Upstreams.fetch(system), true <- mod.fields() != [] do
      {:noreply,
       socket
       |> assign(:linking, mod)
       |> assign(:link_error, nil)
       |> assign(:form, to_form(%{}, as: :credential))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("cancel_link", _params, socket) do
    {:noreply, assign(socket, linking: nil, link_error: nil)}
  end

  def handle_event("link", %{"credential" => params}, socket) do
    mod = socket.assigns.linking

    case Connections.link(socket.assigns.current_scope, mod.system(), params) do
      {:ok, connection} ->
        {:noreply,
         socket
         |> assign(:linking, nil)
         |> put_flash(:info, linked_message(mod, connection))
         |> load()}

      {:error, reason} ->
        {:noreply,
         socket
         # Never echo the secret back into the form.
         |> assign(:form, to_form(%{}, as: :credential))
         |> assign(:link_error, link_error(reason, mod))}
    end
  end

  def handle_event("link", _params, socket), do: {:noreply, socket}

  def handle_event("test", %{"system" => system}, socket) do
    scope = socket.assigns.current_scope

    {:noreply,
     socket
     |> update(:testing, &MapSet.put(&1, system))
     |> start_async({:test, system}, fn -> Connections.test(scope, system) end)}
  end

  def handle_event("unlink", %{"system" => system}, socket) do
    flash =
      case Connections.unlink(socket.assigns.current_scope, system) do
        :ok when system == "github" ->
          {:info, gettext("GitHub disconnected; Switchboard's access was revoked in GitHub.")}

        :ok ->
          {:info, gettext("Key removed.")}

        {:ok, :not_revoked} ->
          {:error,
           gettext(
             "Disconnected, but GitHub couldn't be reached to revoke Switchboard's access. Revoke it in your GitHub settings: %{url}",
             url: Switchboard.GitHub.app_settings_url()
           )}

        {:error, _} ->
          {:error, gettext("Couldn't remove it.")}
      end

    {kind, text} = flash
    {:noreply, socket |> put_flash(kind, text) |> load()}
  end

  @impl true
  def handle_async({:test, system}, result, socket) do
    socket = update(socket, :testing, &MapSet.delete(&1, system))

    message =
      case result do
        {:ok, {:ok, %{status: "ok"}}} -> {:info, gettext("The key works.")}
        {:ok, {:ok, %{status: "rejected"}}} -> {:error, gettext("The key was rejected.")}
        _ -> {:error, gettext("Couldn't reach the system. Try again later.")}
      end

    {kind, text} = message
    {:noreply, socket |> put_flash(kind, text) |> load()}
  end

  defp linked_message(mod, %{status: "ok"}),
    do:
      gettext("%{system} linked. You can delete the key from your computer.", system: mod.label())

  defp linked_message(mod, _),
    do:
      gettext("%{system} saved, but it couldn't be tested now. Test it again later.",
        system: mod.label()
      )

  defp link_error(:rejected, mod),
    do: gettext("%{system} rejected this key. Check it and try again.", system: mod.label())

  defp link_error(:missing_fields, _), do: gettext("Fill in every field.")

  defp link_error(:invalid_format, mod),
    do: gettext("That doesn't look like a %{system} key.", system: mod.label())

  defp link_error(_, _), do: gettext("Couldn't save the key.")
end
