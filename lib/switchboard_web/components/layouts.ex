defmodule SwitchboardWeb.Layouts do
  @moduledoc """
  Layouts (shared with a sibling Phoenix app):

    * `app/1` - the signed-in shell: collapsible sidebar, top bar with breadcrumbs, keyboard
      shortcuts and toasts.
    * `auth/1` - calm centred screens: sign in, OAuth consent, errors.

  The root layout (`layouts/root.html.heex`) holds `<head>` and applies the theme and sidebar
  state before first paint.
  """
  use SwitchboardWeb, :html

  alias Phoenix.LiveView.ColocatedHook
  alias Switchboard.Accounts.User
  alias Switchboard.Scope

  embed_templates "layouts/*"

  @doc false
  # The theme stored on the profile wins for signed-in users; otherwise the root script falls
  # back to localStorage, then to the system setting.
  def theme_pref(%Scope{user: %User{theme: theme}}), do: theme
  def theme_pref(_), do: nil

  ## App shell

  @doc """
  The signed-in app shell. Wrap every app LiveView in it:

      <Layouts.app flash={@flash} current_scope={@current_scope} active={:connections}>
        <:crumb>Connections</:crumb>
        <:actions><.button>Test all</.button></:actions>
        ...
      </Layouts.app>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :active, :atom, default: nil, doc: "the sidebar item to highlight"
  attr :width, :string, default: "default", values: ~w(default wide full)

  slot :crumb do
    attr :navigate, :string
  end

  slot :actions
  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :maintenance, Switchboard.Controls.maintenance_message())

    ~H"""
    <div id="app-shell" phx-hook=".Shortcuts" class="min-h-dvh">
      <.sidebar current_scope={@current_scope} active={@active} />

      <div
        class="fixed inset-0 z-30 hidden bg-black/30 backdrop-blur-[1px] max-md:[[data-mobile-nav]_&]:block"
        phx-click={JS.dispatch("switchboard:close-mobile-nav")}
        aria-hidden="true"
      />

      <div class={[
        "flex min-h-dvh min-w-0 flex-col transition-[padding] duration-(--duration-base) ease-(--ease-out)",
        "md:pl-(--sidebar-width) sidebar-collapsed:md:pl-(--sidebar-rail)"
      ]}>
        <header class="sticky top-0 z-20 flex h-(--topbar-height) items-center gap-2 border-b border-border bg-canvas/85 px-3 backdrop-blur-md supports-[backdrop-filter]:bg-canvas/70">
          <.icon_button
            id="toggle-sidebar"
            icon="hero-bars-3-bottom-left"
            label={gettext("Toggle sidebar")}
            data-shortcut="["
            phx-click={JS.dispatch("switchboard:toggle-sidebar")}
          />
          <nav aria-label={gettext("Breadcrumb")} class="flex min-w-0 items-center gap-1 text-sm">
            <%= for {crumb, i} <- Enum.with_index(@crumb) do %>
              <.icon
                :if={i > 0}
                name="hero-chevron-right-micro"
                class="size-3.5 shrink-0 text-fg-faint"
              />
              <%= if crumb[:navigate] do %>
                <.link
                  navigate={crumb[:navigate]}
                  class="truncate rounded-md px-1.5 py-0.5 text-fg-muted transition-colors hover:bg-hover hover:text-fg"
                >
                  {render_slot(crumb)}
                </.link>
              <% else %>
                <span class="truncate px-1.5 py-0.5 font-medium text-fg" aria-current="page">
                  {render_slot(crumb)}
                </span>
              <% end %>
            <% end %>
          </nav>
          <div class="ml-auto flex items-center gap-1.5">{render_slot(@actions)}</div>
        </header>

        <div
          :if={@maintenance}
          id="maintenance-banner"
          role="status"
          class="flex items-center gap-2 border-b border-border bg-warning-soft px-4 py-2 text-sm text-warning-fg sm:px-8"
        >
          <.icon name="hero-wrench-screwdriver-mini" class="size-4 shrink-0" />
          <span>{@maintenance}</span>
        </div>

        <main
          id="main"
          class={[
            "flex-1 px-4 py-6 [view-transition-name:main] sm:px-8 sm:py-8",
            @width == "default" && "mx-auto w-full max-w-5xl",
            @width == "wide" && "mx-auto w-full max-w-7xl"
          ]}
        >
          {render_slot(@inner_block)}
        </main>
      </div>

      <.shortcuts_sheet current_scope={@current_scope} />

      <%!-- Invisible shortcut targets for navigation (see the .Shortcuts hook). --%>
      <.link
        :for={{path, keys} <- nav_shortcuts(@current_scope)}
        navigate={path}
        data-shortcut={keys}
        class="hidden"
        tabindex="-1"
      ></.link>
      <button
        type="button"
        class="hidden"
        tabindex="-1"
        data-shortcut="?"
        phx-click={open_dialog("shortcuts")}
      />

      <.flash_group flash={@flash} />
    </div>

    <script :type={ColocatedHook} name=".Shortcuts">
      // Keyboard shortcuts. Any element with data-shortcut="<keys>" is clicked
      // (or focused, for inputs) when its keys are pressed. Sequences like
      // "g c" are typed one key after another; "mod+k" is ⌘K / Ctrl+K.
      export default {
        mounted() {
          this.seq = ""
          this.onKey = (e) => {
            const mod = e.metaKey || e.ctrlKey
            if (mod && e.key.toLowerCase() === "k") return this.fire("mod+k", e)
            if (mod || e.altKey || e.repeat) return
            const t = e.target
            if (t.closest?.("input, textarea, select, [contenteditable]")) return
            if (document.querySelector("dialog[open]")) return
            if (e.key.length !== 1) return

            const key = e.key === "?" ? "?" : e.key.toLowerCase()
            const candidate = this.seq ? `${this.seq} ${key}` : key
            clearTimeout(this.timer)

            if (this.fire(candidate, e)) { this.seq = ""; return }
            if (this.hasPrefix(candidate)) {
              this.seq = candidate
              this.timer = setTimeout(() => this.seq = "", 900)
              return
            }
            this.seq = ""
            if (candidate !== key) {
              if (this.fire(key, e)) return
              if (this.hasPrefix(key)) {
                this.seq = key
                this.timer = setTimeout(() => this.seq = "", 900)
              }
            }
          }
          window.addEventListener("keydown", this.onKey)
        },
        find(selector) {
          return Array.from(document.querySelectorAll(selector))
        },
        hasPrefix(seq) {
          return this.find("[data-shortcut]").some(el => el.dataset.shortcut.startsWith(seq + " "))
        },
        fire(seq, e) {
          const el = this.find("[data-shortcut]").find(el => el.dataset.shortcut === seq && !el.disabled)
          if (!el) return false
          e.preventDefault()
          if (el.matches("input, textarea, select")) { el.focus(); el.select?.() }
          else el.click()
          return true
        },
        destroyed() {
          window.removeEventListener("keydown", this.onKey)
          clearTimeout(this.timer)
        }
      }
    </script>
    """
  end

  defp admin?(%Scope{user: %User{admin: true}}), do: true
  defp admin?(_), do: false

  defp nav_shortcuts(scope) do
    [
      {~p"/connections", "g c"},
      {~p"/clients", "g t"},
      {~p"/activity", "g a"},
      {~p"/profile", "g p"}
    ] ++ if(admin?(scope), do: [{~p"/admin", "g x"}], else: [])
  end

  attr :current_scope, :map, required: true
  attr :active, :atom, default: nil

  defp sidebar(assigns) do
    assigns = assign(assigns, :user, assigns.current_scope.user)

    ~H"""
    <aside
      id="sidebar"
      class={[
        "fixed inset-y-0 left-0 z-40 flex w-(--sidebar-width) flex-col border-r border-border bg-sidebar",
        "transition-[width,transform] duration-(--duration-base) ease-(--ease-out)",
        "sidebar-collapsed:md:w-(--sidebar-rail)",
        "max-md:-translate-x-full max-md:shadow-xl max-md:[[data-mobile-nav]_&]:translate-x-0"
      ]}
    >
      <div class="flex h-(--topbar-height) shrink-0 items-center px-2.5">
        <.dropdown id="account-menu" align="start" class="w-full" menu_class="w-56">
          <:trigger>
            <button
              type="button"
              class="flex h-8 w-full min-w-0 cursor-pointer items-center gap-2 rounded-md px-1.5 text-left transition-colors hover:bg-hover active:bg-active"
            >
              <.logo class="size-5.5 shrink-0" />
              <span class="truncate text-sm font-semibold text-fg sidebar-collapsed:md:hidden">
                Switchboard
              </span>
              <.icon
                name="hero-chevron-up-down-micro"
                class="ml-auto size-3.5 text-fg-subtle sidebar-collapsed:md:hidden"
              />
            </button>
          </:trigger>
          <:item label>{@user.username}</:item>
          <:item icon="hero-user-circle-mini" navigate={~p"/profile"}>
            {gettext("Profile")}
          </:item>
          <:item icon="hero-command-line-mini" phx-click={open_dialog("shortcuts")} shortcut="?">
            {gettext("Keyboard shortcuts")}
          </:item>
          <:item separator />
          <:item
            icon="hero-arrow-right-start-on-rectangle-mini"
            href={~p"/auth/logout"}
            method="delete"
          >
            {gettext("Log out")}
          </:item>
        </.dropdown>
      </div>

      <nav
        class="flex flex-1 flex-col gap-0.5 overflow-y-auto px-2.5 py-1"
        aria-label={gettext("Main")}
      >
        <.nav_item
          navigate={~p"/connections"}
          icon="hero-link"
          active={@active == :connections}
          shortcut="G C"
        >
          {gettext("Connections")}
        </.nav_item>
        <.nav_item
          navigate={~p"/clients"}
          icon="hero-key"
          active={@active == :clients}
          shortcut="G T"
        >
          {gettext("Clients and tokens")}
        </.nav_item>
        <.nav_item
          navigate={~p"/activity"}
          icon="hero-queue-list"
          active={@active == :activity}
          shortcut="G A"
        >
          {gettext("My activity")}
        </.nav_item>
        <.nav_item
          navigate={~p"/profile"}
          icon="hero-cog-6-tooth"
          active={@active == :profile}
          shortcut="G P"
        >
          {gettext("Profile")}
        </.nav_item>

        <%= if admin?(@current_scope) do %>
          <div class="mt-4 mb-1 px-2 text-2xs font-medium tracking-wide text-fg-subtle uppercase sidebar-collapsed:md:hidden">
            {gettext("Admin")}
          </div>
          <.nav_item
            navigate={~p"/admin"}
            icon="hero-shield-check"
            active={@active == :admin_controls}
            shortcut="G X"
          >
            {gettext("Controls")}
          </.nav_item>
          <.nav_item
            navigate={~p"/admin/audit"}
            icon="hero-document-magnifying-glass"
            active={@active == :admin_audit}
          >
            {gettext("Audit log")}
          </.nav_item>
          <.nav_item
            navigate={~p"/admin/people"}
            icon="hero-users"
            active={@active == :admin_people}
          >
            {gettext("People")}
          </.nav_item>
          <.nav_item
            navigate={~p"/admin/health"}
            icon="hero-signal"
            active={@active == :admin_health}
          >
            {gettext("Upstream health")}
          </.nav_item>
        <% end %>
      </nav>

      <div class="flex items-center gap-2 border-t border-border p-2.5 sidebar-collapsed:md:flex-col">
        <.link
          navigate={~p"/profile"}
          class="flex min-w-0 flex-1 items-center gap-2 rounded-md p-1 transition-colors hover:bg-hover"
        >
          <.avatar name={User.display_name(@user)} color={User.avatar_color(@user)} size="sm" />
          <span class="min-w-0 sidebar-collapsed:md:hidden">
            <span class="block truncate text-sm font-medium text-fg">{User.display_name(@user)}</span>
            <span class="block truncate text-2xs text-fg-subtle">@{@user.username}</span>
          </span>
        </.link>
        <.theme_toggle id="sidebar-theme" compact />
      </div>
    </aside>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, default: false
  attr :shortcut, :string, default: nil
  slot :inner_block, required: true

  defp nav_item(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      aria-current={@active && "page"}
      class={[
        "group flex h-8 items-center gap-2.5 rounded-md px-2 text-sm font-medium",
        "transition-[background-color,color] duration-(--duration-fast)",
        "sidebar-collapsed:md:justify-center sidebar-collapsed:md:px-0",
        if(@active,
          do: "bg-active text-fg",
          else: "text-fg-muted hover:bg-hover hover:text-fg"
        )
      ]}
    >
      <.icon
        name={@icon}
        class={[
          "size-4.5",
          if(@active, do: "text-fg", else: "text-fg-subtle group-hover:text-fg-muted")
        ]}
      />
      <span class="truncate sidebar-collapsed:md:sr-only">{render_slot(@inner_block)}</span>
      <span
        :if={@shortcut}
        class="ml-auto hidden text-2xs tracking-wider text-fg-faint group-hover:inline sidebar-collapsed:md:!hidden"
      >
        {@shortcut}
      </span>
    </.link>
    """
  end

  @doc """
  The page heading: a title, an optional one-line lead and actions on the right.
  """
  attr :title, :string, required: true
  attr :lead, :string, default: nil
  slot :actions

  def page_header(assigns) do
    ~H"""
    <div class="mb-8 flex flex-wrap items-end justify-between gap-4">
      <div class="min-w-0">
        <h1 class="text-2xl font-semibold text-fg">{@title}</h1>
        <p :if={@lead} class="mt-1 max-w-2xl text-md text-fg-muted">{@lead}</p>
      </div>
      <div :if={@actions != []} class="flex items-center gap-2">{render_slot(@actions)}</div>
    </div>
    """
  end

  ## Keyboard shortcuts sheet

  attr :current_scope, :map, required: true

  defp shortcuts_sheet(assigns) do
    assigns = assign(assigns, :groups, shortcut_groups(assigns.current_scope))

    ~H"""
    <.sheet id="shortcuts" title={gettext("Keyboard shortcuts")} width="24rem">
      <div class="space-y-6">
        <section :for={{group, items} <- @groups}>
          <h3 class="mb-2 text-xs font-medium text-fg-subtle">{group}</h3>
          <ul class="divide-y divide-border rounded-lg border border-border">
            <li
              :for={{label, keys} <- items}
              class="flex items-center justify-between px-3 py-2 text-sm"
            >
              <span class="text-fg">{label}</span>
              <span class="flex items-center gap-1">
                <%= for {key, i} <- Enum.with_index(keys) do %>
                  <span :if={i > 0 and key != "+"} class="text-2xs text-fg-faint">
                    {gettext("then")}
                  </span>
                  <.kbd>{key}</.kbd>
                <% end %>
              </span>
            </li>
          </ul>
        </section>
      </div>
    </.sheet>
    """
  end

  defp shortcut_groups(scope) do
    [
      {gettext("General"),
       [
         {gettext("Show keyboard shortcuts"), ["?"]},
         {gettext("Toggle sidebar"), ["["]}
       ]},
      {gettext("Go to"),
       [
         {gettext("Connections"), ["G", "C"]},
         {gettext("Clients and tokens"), ["G", "T"]},
         {gettext("My activity"), ["G", "A"]},
         {gettext("Profile"), ["G", "P"]}
       ] ++ if(admin?(scope), do: [{gettext("Admin controls"), ["G", "X"]}], else: [])}
    ]
  end

  ## Theme toggle

  @doc """
  Switches between system, light and dark. Applies instantly on the client and, when signed in,
  saves the choice to the profile.
  """
  attr :id, :string, required: true
  attr :compact, :boolean, default: false

  def theme_toggle(assigns) do
    ~H"""
    <div
      id={@id}
      role="radiogroup"
      aria-label={gettext("Theme")}
      class={[
        "relative inline-flex shrink-0 rounded-md bg-hover p-0.5 shadow-[inset_0_0_0_1px_var(--color-border)]",
        @compact && "sidebar-collapsed:md:flex-col"
      ]}
    >
      <button
        :for={
          {theme, icon, label} <- [
            {"system", "hero-computer-desktop-micro", gettext("System theme")},
            {"light", "hero-sun-micro", gettext("Light theme")},
            {"dark", "hero-moon-micro", gettext("Dark theme")}
          ]
        }
        type="button"
        role="radio"
        aria-label={label}
        title={label}
        data-theme-option={theme}
        phx-click={set_theme(theme) |> JS.push("shell:set_theme", value: %{theme: theme})}
        class={[
          "flex size-6 cursor-pointer items-center justify-center rounded-[5px] text-fg-subtle",
          "transition-[background-color,color,box-shadow,transform] duration-(--duration-fast) active:scale-90 hover:text-fg",
          "[[data-theme-pref=system]_&[data-theme-option=system]]:bg-surface [[data-theme-pref=system]_&[data-theme-option=system]]:text-fg [[data-theme-pref=system]_&[data-theme-option=system]]:shadow-sm",
          "[[data-theme-pref=light]_&[data-theme-option=light]]:bg-surface [[data-theme-pref=light]_&[data-theme-option=light]]:text-fg [[data-theme-pref=light]_&[data-theme-option=light]]:shadow-sm",
          "[[data-theme-pref=dark]_&[data-theme-option=dark]]:bg-surface [[data-theme-pref=dark]_&[data-theme-option=dark]]:text-fg [[data-theme-pref=dark]_&[data-theme-option=dark]]:shadow-sm"
        ]}
      >
        <.icon name={icon} class="size-3.5" />
      </button>
    </div>
    """
  end

  ## Auth layout

  @doc """
  A calm, centred layout for screens outside the app: sign in, OAuth consent, errors.
  """
  attr :flash, :map, default: %{}
  attr :current_scope, :map, default: nil
  attr :width, :string, default: "24rem"
  slot :inner_block, required: true
  slot :footer

  def auth(assigns) do
    ~H"""
    <div class="relative flex min-h-dvh flex-col items-center justify-center bg-canvas px-4 py-12">
      <div
        class="pointer-events-none absolute inset-x-0 top-0 h-72 bg-[radial-gradient(60%_100%_at_50%_0%,var(--color-accent-soft),transparent)] opacity-70"
        aria-hidden="true"
      />
      <div class="relative w-full animate-fade-in" style={"max-width: #{@width}"}>
        <div class="mb-8 flex items-center justify-center gap-2.5">
          <.logo class="size-7" />
          <span class="text-lg font-semibold tracking-tight text-fg">Switchboard</span>
        </div>
        <div class="rounded-xl border border-border bg-surface p-6 shadow-md sm:p-8">
          {render_slot(@inner_block)}
        </div>
        <div :if={@footer != []} class="mt-6 text-center text-sm text-fg-muted">
          {render_slot(@footer)}
        </div>
      </div>
      <div class="absolute right-4 bottom-4">
        <.theme_toggle id="auth-theme" />
      </div>
      <.flash_group flash={@flash} />
    </div>
    """
  end

  ## Logo

  attr :class, :any, default: "size-6"

  @doc "The Switchboard mark: a patch panel's two jacks joined by a cord."
  def logo(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" class={@class} aria-hidden="true">
      <rect width="24" height="24" rx="6" fill="var(--color-accent)" />
      <circle cx="7.5" cy="8" r="2" fill="var(--color-on-accent)" />
      <circle cx="16.5" cy="16" r="2" fill="var(--color-on-accent)" />
      <circle cx="16.5" cy="8" r="1.3" fill="var(--color-on-accent)" fill-opacity="0.45" />
      <circle cx="7.5" cy="16" r="1.3" fill="var(--color-on-accent)" fill-opacity="0.45" />
      <path
        d="M7.5 8c0 5 9 3 9 8"
        fill="none"
        stroke="var(--color-on-accent)"
        stroke-width="1.6"
        stroke-linecap="round"
      />
    </svg>
    """
  end

  ## Toasts

  @doc """
  Shows the flash as toasts, plus the reconnecting notices.

  The region is a manual popover so it sits in the top layer, above open dialogs.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div
      id={@id}
      popover="manual"
      phx-hook=".ToastRegion"
      aria-live="polite"
      class="pointer-events-none fixed top-auto right-4 bottom-4 left-auto m-0 flex w-[min(24rem,calc(100vw-2rem))] flex-col gap-2 overflow-visible border-0 bg-transparent p-0"
    >
      <.toast id="flash-info" kind={:info} flash={@flash} />
      <.toast id="flash-error" kind={:error} flash={@flash} />

      <.toast
        id="client-error"
        kind={:error}
        title={gettext("Connection lost")}
        autodismiss={false}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Reconnecting…")}
      </.toast>

      <.toast
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong")}
        autodismiss={false}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Reconnecting…")}
      </.toast>

      <div id="client-toasts" phx-update="ignore" class="flex flex-col gap-2"></div>
      <.toast_template />
    </div>
    <script :type={ColocatedHook} name=".ToastRegion">
      // Keep the toast region in the top layer and above any open dialog:
      // re-showing a popover moves it to the top of the stack. Only needed
      // while a dialog is open (re-showing replays the toasts' entry motion).
      export default {
        mounted() {
          this.show = () => {
            if (!this.el.showPopover) return
            try { if (this.el.matches(":popover-open")) this.el.hidePopover() } catch (_e) {}
            try { this.el.showPopover() } catch (_e) {}
          }
          this.raise = () => document.querySelector("dialog[open]") && this.show()
          this.show()
          this.observer = new MutationObserver(this.raise)
          this.observer.observe(this.el, {childList: true})
          this.observer.observe(this.el.querySelector("#client-toasts"), {childList: true})
          window.addEventListener("switchboard:dialog-open", this.onDialog = () => setTimeout(this.raise))
        },
        destroyed() {
          this.observer?.disconnect()
          window.removeEventListener("switchboard:dialog-open", this.onDialog)
        }
      }
    </script>
    """
  end
end
