defmodule SwitchboardWeb.OverlayComponents do
  @moduledoc """
  Things that float above the page: dialogs, sheets, dropdown menus, tooltips
  and toasts.

  Dialogs and sheets are native `<dialog>` elements opened with `showModal()`,
  which gives focus trapping, Esc to close and the top layer for free. Open
  and close them with `open_dialog/2` and `close_dialog/2` (JS commands), or
  render them with `show` to open on mount.
  """
  use Phoenix.Component
  use Gettext, backend: SwitchboardWeb.Gettext

  import SwitchboardWeb.CoreComponents,
    only: [icon: 1, icon_button: 1, kbd: 1, tooltip_classes: 1]

  alias Phoenix.LiveView.ColocatedHook
  alias Phoenix.LiveView.JS

  ## Dialog and sheet

  @doc """
  A modal dialog.

      <.button phx-click={open_dialog("invite")}>Invite</.button>
      <.dialog id="invite" title={gettext("Invite people")}>
        ...
        <:footer>
          <.button phx-click={close_dialog("invite")}>Cancel</.button>
        </:footer>
      </.dialog>

  `on_close` runs whenever it closes (Esc, backdrop, close button).
  """
  attr :id, :string, required: true
  attr :title, :string, default: nil
  attr :description, :string, default: nil
  attr :show, :boolean, default: false, doc: "open as soon as it is mounted"
  attr :on_close, JS, default: %JS{}
  attr :width, :string, default: "32rem"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true
  slot :footer

  def dialog(assigns) do
    ~H"""
    <dialog
      id={@id}
      class={["ui-dialog", @class]}
      style={"--dialog-width: #{@width}"}
      aria-labelledby={@title && "#{@id}-title"}
      data-on-close={@on_close}
      phx-mounted={mount_dialog(@show)}
      {@rest}
    >
      <div class="flex max-h-[inherit] flex-col">
        <header :if={@title} class="flex items-start justify-between gap-4 px-5 pt-4 pb-1">
          <div class="min-w-0">
            <h2 id={"#{@id}-title"} class="text-lg font-semibold text-fg">{@title}</h2>
            <p :if={@description} class="mt-0.5 text-sm text-fg-muted">{@description}</p>
          </div>
          <.icon_button
            icon="hero-x-mark-mini"
            label={gettext("Close")}
            size="sm"
            tooltip={false}
            class="-mt-0.5 -mr-2"
            phx-click={close_dialog(@id)}
          />
        </header>
        <div class="min-h-0 flex-1 overflow-y-auto px-5 py-4">{render_slot(@inner_block)}</div>
        <footer
          :if={@footer != []}
          class="flex items-center justify-end gap-2 border-t border-border bg-inset px-5 py-3"
        >
          {render_slot(@footer)}
        </footer>
      </div>
    </dialog>
    """
  end

  @doc """
  A side sheet: a dialog that slides in from the right. Same API as `dialog/1`.
  """
  attr :id, :string, required: true
  attr :title, :string, default: nil
  attr :description, :string, default: nil
  attr :show, :boolean, default: false
  attr :on_close, JS, default: %JS{}
  attr :width, :string, default: "28rem"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true
  slot :footer

  def sheet(assigns) do
    ~H"""
    <dialog
      id={@id}
      class={["ui-dialog ui-sheet", @class]}
      style={"--dialog-width: #{@width}"}
      aria-labelledby={@title && "#{@id}-title"}
      data-on-close={@on_close}
      phx-mounted={mount_dialog(@show)}
      {@rest}
    >
      <div class="flex h-full flex-col">
        <header
          :if={@title}
          class="flex items-start justify-between gap-4 border-b border-border px-5 py-4"
        >
          <div class="min-w-0">
            <h2 id={"#{@id}-title"} class="text-lg font-semibold text-fg">{@title}</h2>
            <p :if={@description} class="mt-0.5 text-sm text-fg-muted">{@description}</p>
          </div>
          <.icon_button
            icon="hero-x-mark-mini"
            label={gettext("Close")}
            size="sm"
            tooltip={false}
            class="-mt-0.5 -mr-2"
            phx-click={close_dialog(@id)}
          />
        </header>
        <div class="min-h-0 flex-1 overflow-y-auto px-5 py-4">{render_slot(@inner_block)}</div>
        <footer
          :if={@footer != []}
          class="flex items-center justify-end gap-2 border-t border-border bg-inset px-5 py-3"
        >
          {render_slot(@footer)}
        </footer>
      </div>
    </dialog>
    """
  end

  # The `open` attribute is owned by the browser once mounted; tell LiveView not
  # to strip it on patches.
  defp mount_dialog(show) do
    js = JS.ignore_attributes(["open"])
    if show, do: JS.dispatch(js, "switchboard:dialog-open"), else: js
  end

  @doc "Opens the dialog or sheet with the given id."
  def open_dialog(js \\ %JS{}, id) when is_binary(id) do
    JS.dispatch(js, "switchboard:dialog-open", to: "##{id}")
  end

  @doc "Closes the dialog or sheet with the given id."
  def close_dialog(js \\ %JS{}, id) when is_binary(id) do
    JS.dispatch(js, "switchboard:dialog-close", to: "##{id}")
  end

  ## Dropdown menu

  @doc """
  A dropdown menu. Items are buttons (pass `phx-click`), or links when given
  `navigate`, `patch` or `href`. Closes on click away and Esc.

      <.dropdown id="row-1-menu">
        <:trigger>
          <.icon_button icon="hero-ellipsis-horizontal" label={gettext("Actions")} />
        </:trigger>
        <:item icon="hero-pencil-square-mini" phx-click="rename">Rename</:item>
        <:item separator />
        <:item icon="hero-trash-mini" danger phx-click="delete">Delete</:item>
      </.dropdown>
  """
  attr :id, :string, required: true
  attr :align, :string, default: "end", values: ~w(start end)
  attr :class, :any, default: nil
  attr :menu_class, :any, default: nil
  slot :trigger, required: true

  # Item keys: icon, danger, separator, label (a non-interactive heading),
  # shortcut, navigate/patch/href/method for links, and any phx-* attribute
  # (phx-click, phx-value-*) for buttons. Left undeclared so phx-* pass through.
  slot :item, validate_attrs: false

  def dropdown(assigns) do
    ~H"""
    <div
      id={@id}
      class={["relative inline-flex", @class]}
      phx-click-away={close_dropdown(@id)}
      phx-window-keydown={close_dropdown(@id)}
      phx-key="Escape"
    >
      <div
        phx-click={toggle_dropdown(@id)}
        aria-haspopup="menu"
        aria-controls={"#{@id}-menu"}
        class="inline-flex"
      >
        {render_slot(@trigger)}
      </div>
      <div
        id={"#{@id}-menu"}
        role="menu"
        hidden
        class={[
          "absolute top-full z-50 mt-1 min-w-48 origin-top rounded-lg border border-border bg-raised p-1 shadow-lg",
          if(@align == "end", do: "right-0 origin-top-right", else: "left-0 origin-top-left"),
          @menu_class
        ]}
      >
        <%= for item <- @item do %>
          <%= cond do %>
            <% item[:separator] -> %>
              <div role="separator" class="-mx-1 my-1 h-px bg-border" />
            <% item[:label] -> %>
              <div class="px-2 pt-1.5 pb-1 text-2xs font-medium text-fg-subtle">
                {render_slot(item)}
              </div>
            <% item[:navigate] || item[:patch] || item[:href] -> %>
              <.link
                role="menuitem"
                navigate={item[:navigate]}
                patch={item[:patch]}
                href={item[:href]}
                method={item[:method]}
                class={menu_item_class(item[:danger])}
                phx-click={close_dropdown(@id)}
              >
                <.icon :if={item[:icon]} name={item[:icon]} class="size-4 opacity-80" />
                <span class="flex-1">{render_slot(item)}</span>
                <.kbd :if={item[:shortcut]}>{item[:shortcut]}</.kbd>
              </.link>
            <% true -> %>
              <button
                type="button"
                role="menuitem"
                class={menu_item_class(item[:danger])}
                {menu_item_attrs(item, @id)}
              >
                <.icon :if={item[:icon]} name={item[:icon]} class="size-4 opacity-80" />
                <span class="flex-1 text-left">{render_slot(item)}</span>
                <.kbd :if={item[:shortcut]}>{item[:shortcut]}</.kbd>
              </button>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # Item buttons close the menu, then run their own phx-click (JS or event).
  defp menu_item_attrs(item, id) do
    attrs =
      Phoenix.Component.assigns_to_attributes(item, [
        :icon,
        :danger,
        :separator,
        :label,
        :shortcut
      ])

    {click, attrs} = Keyword.pop(attrs, :"phx-click")

    click =
      case click do
        %JS{} = js -> close_dropdown(js, id)
        event when is_binary(event) -> close_dropdown(id) |> JS.push(event, value: values(attrs))
        nil -> close_dropdown(id)
      end

    Keyword.put(attrs, :"phx-click", click)
  end

  # Preserve phx-value-* when turning a string event into a JS.push.
  defp values(attrs) do
    for {key, value} <- attrs,
        key = Atom.to_string(key),
        String.starts_with?(key, "phx-value-"),
        into: %{},
        do: {String.replace_prefix(key, "phx-value-", ""), value}
  end

  defp menu_item_class(danger) do
    [
      "flex w-full cursor-pointer select-none items-center gap-2 rounded-md px-2 py-1.5 text-sm outline-none",
      "transition-colors duration-(--duration-fast) focus-visible:bg-hover active:bg-active",
      if(danger,
        do: "text-danger-fg hover:bg-danger-soft",
        else: "text-fg hover:bg-hover"
      )
    ]
  end

  @doc false
  def toggle_dropdown(js \\ %JS{}, id) do
    js
    |> JS.toggle(
      to: "##{id}-menu",
      time: 160,
      in:
        {"transition-[opacity,transform] duration-(--duration-fast) ease-(--ease-out)",
         "opacity-0 scale-[0.97] -translate-y-0.5", "opacity-100 scale-100 translate-y-0"},
      out:
        {"transition-[opacity,transform] duration-(--duration-fast) ease-(--ease-in)",
         "opacity-100 scale-100", "opacity-0 scale-[0.97]"}
    )
    |> JS.toggle_attribute({"data-open", ""}, to: "##{id}")
  end

  @doc false
  def close_dropdown(js \\ %JS{}, id) do
    js
    |> JS.hide(
      to: "##{id}-menu",
      time: 120,
      transition:
        {"transition-[opacity,transform] duration-(--duration-fast) ease-(--ease-in)",
         "opacity-100 scale-100", "opacity-0 scale-[0.97]"}
    )
    |> JS.remove_attribute("data-open", to: "##{id}")
  end

  ## Tooltip

  @doc """
  Wraps content with a CSS-only tooltip (hover after a beat, or keyboard focus).

      <.tooltip text={gettext("Copy link")}><.button>…</.button></.tooltip>
  """
  attr :text, :string, required: true
  attr :side, :string, default: "top", values: ~w(top bottom left right)
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def tooltip(assigns) do
    ~H"""
    <span class={["ui-has-tooltip relative inline-flex", @class]}>
      {render_slot(@inner_block)}
      <span role="tooltip" class={tooltip_classes(@side)}>{@text}</span>
    </span>
    """
  end

  ## Toasts

  @doc """
  A toast. Server toasts come from the flash (see `Layouts.flash_group/1`);
  client toasts (e.g. "Link copied") are cloned from the same markup in
  `toast_template/1`.
  """
  attr :id, :string, required: true
  attr :kind, :atom, values: [:info, :success, :error]
  attr :title, :string, default: nil
  attr :flash, :map, default: %{}
  attr :autodismiss, :boolean, default: true
  attr :rest, :global
  slot :inner_block

  def toast(assigns) do
    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      role={if(@kind == :error, do: "alert", else: "status")}
      phx-hook={@autodismiss && "SwitchboardWeb.OverlayComponents.Toast"}
      class="ui-enter pointer-events-auto flex w-full items-start gap-3 rounded-lg border border-border bg-raised p-3 pr-2 text-sm shadow-lg"
      {@rest}
    >
      <span class={[
        "mt-px flex size-5 shrink-0 items-center justify-center rounded-full",
        @kind == :error && "bg-danger-soft text-danger-fg",
        @kind == :success && "bg-success-soft text-success-fg",
        @kind == :info && "bg-accent-soft text-accent-fg"
      ]}>
        <.icon :if={@kind == :error} name="hero-exclamation-triangle-micro" class="size-3.5" />
        <.icon :if={@kind == :success} name="hero-check-micro" class="size-3.5" />
        <.icon :if={@kind == :info} name="hero-information-circle-micro" class="size-3.5" />
      </span>
      <div class="min-w-0 flex-1 pt-px">
        <p :if={@title} class="font-medium text-fg">{@title}</p>
        <p class="text-fg-muted">{msg}</p>
      </div>
      <button
        type="button"
        data-dismiss
        class="-my-0.5 flex size-6 cursor-pointer items-center justify-center rounded-md text-fg-subtle transition-colors hover:bg-hover hover:text-fg"
        aria-label={gettext("Dismiss")}
        phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide_toast("##{@id}")}
      >
        <.icon name="hero-x-mark-mini" class="size-4" />
      </button>
    </div>
    <%!-- Referenced by its full name above: the "." shorthand only expands in
         static phx-hook attributes, and this one is conditional. --%>
    <script :type={ColocatedHook} name=".Toast">
      // Dismiss after a few seconds; hovering pauses the countdown.
      export default {
        mounted() {
          this.remaining = 5000
          this.start()
          this.el.addEventListener("mouseenter", () => this.pause())
          this.el.addEventListener("mouseleave", () => this.start())
        },
        start() {
          this.startedAt = Date.now()
          this.timer = setTimeout(() => this.el.querySelector("[data-dismiss]")?.click(), this.remaining)
        },
        pause() {
          clearTimeout(this.timer)
          this.remaining -= Date.now() - this.startedAt
        },
        destroyed() { clearTimeout(this.timer) }
      }
    </script>
    """
  end

  @doc false
  def hide_toast(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 160,
      transition:
        {"transition-[opacity,transform] duration-(--duration-fast) ease-(--ease-in)",
         "opacity-100 translate-y-0 scale-100", "opacity-0 translate-y-1 scale-[0.98]"}
    )
  end

  @doc """
  The `<template>` that client-side toasts are cloned from (see app.js).
  Rendered once in the layout.
  """
  def toast_template(assigns) do
    ~H"""
    <template id="toast-template">
      <div class="ui-enter pointer-events-auto flex w-full items-start gap-3 rounded-lg border border-border bg-raised p-3 pr-2 text-sm shadow-lg transition-[opacity,transform] duration-(--duration-base) data-[kind=error]:[&_[data-icon-ok]]:hidden data-[kind=info]:[&_[data-icon-error]]:hidden">
        <span
          data-icon-ok
          class="mt-px flex size-5 shrink-0 items-center justify-center rounded-full bg-success-soft text-success-fg"
        >
          <.icon name="hero-check-micro" class="size-3.5" />
        </span>
        <span
          data-icon-error
          class="mt-px flex size-5 shrink-0 items-center justify-center rounded-full bg-danger-soft text-danger-fg"
        >
          <.icon name="hero-exclamation-triangle-micro" class="size-3.5" />
        </span>
        <p data-toast-message class="min-w-0 flex-1 pt-px text-fg"></p>
        <button
          type="button"
          data-toast-close
          class="-my-0.5 flex size-6 cursor-pointer items-center justify-center rounded-md text-fg-subtle hover:bg-hover hover:text-fg"
          aria-label={gettext("Dismiss")}
        >
          <.icon name="hero-x-mark-mini" class="size-4" />
        </button>
      </div>
    </template>
    """
  end
end
