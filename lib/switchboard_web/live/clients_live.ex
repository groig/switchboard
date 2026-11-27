defmodule SwitchboardWeb.ClientsLive do
  @moduledoc """
  The person's MCP clients (OAuth grants) and personal gateway tokens: see them, revoke them,
  and create a token (shown once).
  """
  use SwitchboardWeb, :live_view

  alias Switchboard.{OAuth, PersonalTokens}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Clients and tokens"))
     |> assign(:mcp_url, OAuth.resource())
     |> assign(:new_token, nil)
     |> assign(:token_error, nil)
     |> assign(:token_form, token_form())
     |> load()}
  end

  defp token_form(params \\ %{"name" => "", "expires" => "90"}),
    do: to_form(params, as: :token)

  defp load(socket) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:grant_groups, OAuth.grant_groups(scope.user))
    |> assign(:tokens, PersonalTokens.list(scope))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:clients}>
      <:crumb>{gettext("Clients and tokens")}</:crumb>

      <Layouts.page_header
        title={gettext("Clients and tokens")}
        lead={
          gettext("Everything that can call Switchboard as you. Revoke anything you don't recognise.")
        }
      />

      <section id="connect-help" class="mb-10">
        <h2 class="mb-2 text-md font-semibold text-fg">{gettext("Connect an agent")}</h2>
        <div class="divide-y divide-border overflow-hidden rounded-lg border border-border bg-inset font-mono text-xs">
          <div :for={cmd <- connect_commands(@mcp_url)} class="flex items-center gap-2 px-3 py-2">
            <code class="min-w-0 flex-1 overflow-x-auto whitespace-nowrap text-fg">{cmd}</code>
            <.icon_button
              icon="hero-clipboard-document-mini"
              label={gettext("Copy")}
              phx-click={copy(cmd, gettext("Copied"))}
            />
          </div>
        </div>
        <p class="mt-2 text-sm text-fg-subtle">
          {gettext("Your browser opens to sign in with Forgejo and approve the client.")}
        </p>
      </section>

      <section id="grants" class="mb-10">
        <h2 class="mb-3 text-md font-semibold text-fg">{gettext("Connected clients")}</h2>
        <.table id="grants-table" rows={@grant_groups} row_id={&"grant-group-#{group_dom_id(&1.key)}"}>
          <:col :let={group} label={gettext("Client")}>
            <div class="flex items-center gap-2">
              <span class="font-medium text-fg">{group.name || gettext("Unnamed client")}</span>
              <.badge :if={length(group.grants) > 1} id={"grant-count-#{group_dom_id(group.key)}"}>
                {ngettext("%{count} connection", "%{count} connections", length(group.grants))}
              </.badge>
            </div>
            <div class="max-w-sm truncate font-mono text-2xs text-fg-subtle">
              {group.latest.client_id}
            </div>
            <p :if={length(group.grants) > 1} class="mt-1 text-xs text-fg-subtle">
              {gettext(
                "The client registered itself again on each sign-in. Only the most recently used connection is likely still in use."
              )}
            </p>
          </:col>
          <:col :let={group} label={gettext("Connected")}>
            <.relative_time at={group.latest.inserted_at} scope={@current_scope} />
          </:col>
          <:col :let={group} label={gettext("Last used")}>
            <.relative_time at={group.latest.last_used_at} scope={@current_scope} />
          </:col>
          <:action :let={group}>
            <div class="flex justify-end gap-2">
              <.button
                :if={length(group.grants) > 1}
                id={"remove-stale-#{group_dom_id(group.key)}"}
                size="sm"
                phx-click="remove_stale"
                phx-value-key={group.key}
                data-confirm={
                  ngettext(
                    "Disconnect the older connection of this client? The most recently used one stays.",
                    "Disconnect the %{count} older connections of this client? The most recently used one stays.",
                    length(group.grants) - 1
                  )
                }
              >
                {ngettext("Remove %{count} older", "Remove %{count} older", length(group.grants) - 1)}
              </.button>
              <.button
                id={"revoke-group-#{group_dom_id(group.key)}"}
                size="sm"
                phx-click="revoke_group"
                phx-value-key={group.key}
                data-confirm={gettext("Disconnect this client? It will have to sign in again.")}
              >
                {gettext("Revoke")}
              </.button>
            </div>
          </:action>
          <:empty>
            <.empty_state icon="hero-cpu-chip" title={gettext("No clients yet")}>
              {gettext("Connect Claude Code or Codex with one of the commands above.")}
            </.empty_state>
          </:empty>
        </.table>
      </section>

      <section id="personal-tokens">
        <div class="mb-3 flex items-end justify-between gap-4">
          <div>
            <h2 class="text-md font-semibold text-fg">{gettext("Personal tokens")}</h2>
            <p class="text-sm text-fg-muted">
              {gettext("For MCP clients without OAuth. Send it as an Authorization: Bearer header.")}
            </p>
          </div>
          <.button
            id="new-token"
            size="sm"
            icon="hero-plus-mini"
            phx-click={JS.push("new_token") |> open_dialog("token-dialog")}
          >
            {gettext("New token")}
          </.button>
        </div>
        <.table id="tokens-table" rows={@tokens} row_id={&"token-#{&1.id}"}>
          <:col :let={token} label={gettext("Name")}>
            <div class="font-medium text-fg">{token.name}</div>
            <div class="font-mono text-2xs text-fg-subtle">{token.hint}…</div>
          </:col>
          <:col :let={token} label={gettext("Expires")}>
            <%= if token.expires_at do %>
              {Format.date(token.expires_at, @current_scope)}
            <% else %>
              <span class="text-fg-subtle">{gettext("Never")}</span>
            <% end %>
          </:col>
          <:col :let={token} label={gettext("Last used")}>
            <.relative_time at={token.last_used_at} scope={@current_scope} />
          </:col>
          <:action :let={token}>
            <.button
              id={"revoke-token-#{token.id}"}
              size="sm"
              phx-click="revoke_token"
              phx-value-id={token.id}
              data-confirm={gettext("Revoke this token? Clients using it stop working at once.")}
            >
              {gettext("Revoke")}
            </.button>
          </:action>
          <:empty>
            <.empty_state icon="hero-key" title={gettext("No personal tokens")} />
          </:empty>
        </.table>
      </section>

      <.dialog
        id="token-dialog"
        title={gettext("New personal token")}
        on_close={JS.push("close_token")}
      >
        <%= if @new_token do %>
          <div id="token-created" class="space-y-3">
            <p class="text-sm text-fg-muted">
              {gettext("Copy it now: Switchboard can't show it again.")}
            </p>
            <div class="flex items-center gap-2 rounded-lg border border-border bg-inset px-3 py-2">
              <code id="token-value" class="min-w-0 flex-1 font-mono text-xs break-all text-fg">
                {@new_token}
              </code>
              <.icon_button
                icon="hero-clipboard-document-mini"
                label={gettext("Copy")}
                phx-click={copy(@new_token, gettext("Copied"))}
              />
            </div>
            <div class="flex justify-end">
              <.button variant="primary" phx-click={close_dialog("token-dialog")}>
                {gettext("Done")}
              </.button>
            </div>
          </div>
        <% else %>
          <.form for={@token_form} id="token-form" phx-submit="create_token" class="space-y-4">
            <.input
              field={@token_form[:name]}
              label={gettext("Name")}
              placeholder={gettext("e.g. Zed on my laptop")}
              autocomplete="off"
              required
            />
            <.input
              field={@token_form[:expires]}
              type="select"
              label={gettext("Expires")}
              options={expiry_options()}
            />
            <p :if={@token_error} id="token-error" class="text-sm text-danger-fg">{@token_error}</p>
            <div class="flex justify-end gap-2">
              <.button phx-click={close_dialog("token-dialog")}>{gettext("Cancel")}</.button>
              <.button type="submit" variant="primary">{gettext("Create token")}</.button>
            </div>
          </.form>
        <% end %>
      </.dialog>
    </Layouts.app>
    """
  end

  defp connect_commands(url) do
    [
      "claude mcp add --transport http switchboard #{url}",
      "codex mcp add switchboard --url #{url}"
    ]
  end

  defp expiry_options do
    Enum.map(
      PersonalTokens.expiry_days(),
      &{ngettext("%{count} day", "%{count} days", &1), "#{&1}"}
    ) ++
      [{gettext("Never"), "never"}]
  end

  @doc false
  def group_dom_id(key),
    do: :crypto.hash(:sha256, key) |> Base.url_encode64(padding: false) |> binary_part(0, 10)

  @impl true
  def handle_event("revoke_group", %{"key" => key}, socket) do
    case OAuth.revoke_grant_group(socket.assigns.current_scope, key) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, gettext("Client disconnected.")) |> load()}

      {:error, :not_found} ->
        {:noreply, load(socket)}
    end
  end

  def handle_event("remove_stale", %{"key" => key}, socket) do
    case OAuth.revoke_grant_group(socket.assigns.current_scope, key, keep_latest: true) do
      {:ok, count} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           ngettext(
             "Removed %{count} older connection.",
             "Removed %{count} older connections.",
             count
           )
         )
         |> load()}

      {:error, :not_found} ->
        {:noreply, load(socket)}
    end
  end

  def handle_event("revoke_token", %{"id" => id}, socket) do
    _ = PersonalTokens.revoke(socket.assigns.current_scope, id)
    {:noreply, socket |> put_flash(:info, gettext("Token revoked.")) |> load()}
  end

  def handle_event("new_token", _params, socket) do
    {:noreply, assign(socket, new_token: nil, token_error: nil, token_form: token_form())}
  end

  def handle_event("create_token", %{"token" => params}, socket) do
    expires =
      case params["expires"] do
        "never" -> nil
        days -> String.to_integer(days)
      end

    case PersonalTokens.create(socket.assigns.current_scope, params["name"], expires) do
      {:ok, plaintext, _token} ->
        {:noreply, socket |> assign(:new_token, plaintext) |> load()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:token_form, token_form(params))
         |> assign(:token_error, token_error(reason))}
    end
  rescue
    ArgumentError -> {:noreply, assign(socket, :token_error, token_error(:invalid_expiry))}
  end

  def handle_event("close_token", _params, socket) do
    # Forget the plaintext as soon as the dialog closes.
    {:noreply, assign(socket, new_token: nil)}
  end

  defp token_error(:name_required), do: gettext("Give the token a name.")
  defp token_error(:too_many), do: gettext("You have too many tokens. Revoke one first.")
  defp token_error(_), do: gettext("Choose an expiry from the list.")
end
