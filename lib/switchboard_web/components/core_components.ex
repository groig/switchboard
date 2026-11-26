defmodule SwitchboardWeb.CoreComponents do
  @moduledoc """
  Core UI primitives (shared with a sibling Phoenix app): buttons, form controls, badges, avatars,
  cards, tables, tabs, skeletons and friends.

  Everything here is styled with the design tokens defined in
  `assets/css/app.css` (no daisyUI, no third-party component library).
  Overlays live in `SwitchboardWeb.OverlayComponents`. Both are imported everywhere through
  `SwitchboardWeb.html_helpers/0`, and showcased at `/dev/design`.
  """
  use Phoenix.Component
  use Gettext, backend: SwitchboardWeb.Gettext

  alias Phoenix.LiveView.JS

  ## Icon

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Outline by default; use the `-solid`, `-mini` or `-micro` suffix for the
  other styles.

      <.icon name="hero-x-mark" />
      <.icon name="hero-document-text-mini" class="size-4 text-fg-subtle" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"
  attr :rest, :global

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={["shrink-0", @name, @class]} aria-hidden="true" {@rest} />
    """
  end

  ## Buttons

  @button_base [
    "ui-btn inline-flex shrink-0 cursor-pointer select-none items-center justify-center gap-1.5",
    "whitespace-nowrap font-medium outline-none",
    "transition-[background-color,border-color,color,box-shadow,transform]",
    "duration-(--duration-fast) ease-(--ease-out) active:scale-[0.97] active:duration-75",
    "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring",
    "disabled:pointer-events-none disabled:opacity-45 aria-disabled:pointer-events-none aria-disabled:opacity-45"
  ]

  @button_variants %{
    "primary" => "bg-accent text-on-accent shadow-sm hover:bg-accent-hover",
    "secondary" =>
      "border border-border-strong bg-surface text-fg shadow-xs hover:bg-hover active:bg-active",
    "ghost" => "text-fg-muted hover:bg-hover hover:text-fg active:bg-active",
    "danger" => "bg-danger text-white shadow-sm hover:bg-danger-hover"
  }

  @button_sizes %{
    "xs" => "h-6 rounded-sm px-2 text-xs",
    "sm" => "h-7 rounded-md px-2.5 text-sm",
    "md" => "h-8 rounded-md px-3 text-sm",
    "lg" => "h-10 rounded-lg px-4 text-base"
  }

  @doc """
  Renders a button, or a link styled as one when given `navigate`, `patch` or
  `href`.

  Every button has a pressed state. `loading` shows a shimmer and blocks
  clicks; submit buttons get the same automatically while their form submits,
  and `phx-click` buttons while their event is in flight.

      <.button variant="primary" phx-click="save">Save</.button>
      <.button variant="secondary" icon="hero-plus-mini" navigate={~p"/documents"}>New</.button>
      <.button variant="danger" loading>Deleting</.button>
  """
  attr :variant, :string, default: "secondary", values: ~w(primary secondary ghost danger)
  attr :size, :string, default: "md", values: ~w(xs sm md lg)
  attr :icon, :string, default: nil, doc: "a leading hero icon"
  attr :trailing_icon, :string, default: nil
  attr :loading, :boolean, default: false
  attr :class, :any, default: nil
  attr :type, :string, default: "button"

  attr :for, :string, default: nil, doc: "render as a <label> for this input (e.g. a file input)"

  attr :rest, :global,
    include: ~w(href navigate patch method download name value disabled form replace target rel)

  slot :inner_block, required: true

  def button(assigns) do
    assigns =
      assign(assigns,
        classes: [
          @button_base,
          Map.fetch!(@button_variants, assigns.variant),
          Map.fetch!(@button_sizes, assigns.size),
          assigns.class
        ]
      )

    cond do
      assigns.for ->
        ~H"""
        <label for={@for} class={@classes} role="button" tabindex="0" {@rest}>
          <.icon :if={@icon} name={@icon} class="size-4 -ml-0.5" />
          {render_slot(@inner_block)}
        </label>
        """

      assigns.rest[:href] || assigns.rest[:navigate] || assigns.rest[:patch] ->
        button_link(assigns)

      true ->
        button_element(assigns)
    end
  end

  defp button_link(assigns) do
    ~H"""
    <.link class={@classes} data-loading={@loading} {@rest}>
      <.icon :if={@icon} name={@icon} class="size-4 -ml-0.5" />
      {render_slot(@inner_block)}
      <.icon :if={@trailing_icon} name={@trailing_icon} class="size-4 -mr-0.5" />
    </.link>
    """
  end

  defp button_element(assigns) do
    ~H"""
    <button
      type={@type}
      class={@classes}
      data-loading={@loading}
      aria-busy={@loading && "true"}
      {@rest}
    >
      <.icon :if={@icon} name={@icon} class="size-4 -ml-0.5" />
      {render_slot(@inner_block)}
      <.icon :if={@trailing_icon} name={@trailing_icon} class="size-4 -mr-0.5" />
    </button>
    """
  end

  @icon_button_sizes %{
    "xs" => {"size-6 rounded-sm", "size-3.5"},
    "sm" => {"size-7 rounded-md", "size-4"},
    "md" => {"size-8 rounded-md", "size-4"},
    "lg" => {"size-10 rounded-lg", "size-5"}
  }

  @doc """
  A square button holding a single icon. `label` is required: it becomes the
  accessible name and the tooltip.

      <.icon_button icon="hero-ellipsis-horizontal" label={gettext("More")} />
  """
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :variant, :string, default: "ghost", values: ~w(primary secondary ghost danger)
  attr :size, :string, default: "sm", values: ~w(xs sm md lg)
  attr :tooltip, :boolean, default: true
  attr :tooltip_side, :string, default: "bottom", values: ~w(top bottom left right)
  attr :class, :any, default: nil
  attr :type, :string, default: "button"
  attr :rest, :global, include: ~w(href navigate patch method disabled form name value)

  def icon_button(assigns) do
    {size_class, icon_class} = Map.fetch!(@icon_button_sizes, assigns.size)

    assigns =
      assign(assigns,
        classes: [
          @button_base,
          Map.fetch!(@button_variants, assigns.variant),
          size_class,
          assigns.class
        ],
        icon_class: icon_class
      )

    ~H"""
    <span class="ui-has-tooltip relative inline-flex">
      <%= if @rest[:href] || @rest[:navigate] || @rest[:patch] do %>
        <.link class={@classes} aria-label={@label} {@rest}>
          <.icon name={@icon} class={@icon_class} />
        </.link>
      <% else %>
        <button type={@type} class={@classes} aria-label={@label} {@rest}>
          <.icon name={@icon} class={@icon_class} />
        </button>
      <% end %>
      <span :if={@tooltip} role="tooltip" class={tooltip_classes(@tooltip_side)}>{@label}</span>
    </span>
    """
  end

  @doc false
  def tooltip_classes(side) do
    [
      "ui-tooltip rounded-md bg-fg px-2 py-1 text-xs font-medium text-canvas shadow-md",
      case side do
        "top" -> "bottom-full left-1/2 mb-1.5 -translate-x-1/2"
        "bottom" -> "top-full left-1/2 mt-1.5 -translate-x-1/2"
        "left" -> "right-full top-1/2 mr-1.5 -translate-y-1/2"
        "right" -> "left-full top-1/2 ml-1.5 -translate-y-1/2"
      end
    ]
  end

  ## Forms

  @control_base [
    "block w-full rounded-md border bg-surface text-fg shadow-xs",
    "text-[16px] sm:text-sm placeholder:text-fg-subtle",
    "transition-[border-color,box-shadow] duration-(--duration-fast) ease-(--ease-out)",
    "focus:outline-none focus:ring-3",
    "disabled:cursor-not-allowed disabled:bg-inset disabled:text-fg-subtle",
    "read-only:bg-inset"
  ]

  defp control_base, do: @control_base

  defp control_state(true = _error?),
    do: "border-danger focus:border-danger focus:ring-danger/20"

  defp control_state(false),
    do: "border-border-strong hover:border-fg-faint focus:border-accent focus:ring-accent/20"

  @doc """
  Renders a form control with label, hint and errors.

  Pass a `Phoenix.HTML.FormField` as `field` (preferred), or `name`/`value`.

  Types: any HTML input type, plus `textarea`, `select`, `checkbox`, `switch`
  (a boolean toggle) and `segmented` (a radio group shown as a segmented
  control, given `options`).

      <.input field={@form[:email]} type="email" label={gettext("Email")} />
      <.input field={@form[:role]} type="select" options={@role_options} />
      <.input field={@form[:enabled]} type="switch" label={gettext("Enabled")} />
      <.input field={@form[:view]} type="segmented" options={[{"Grid", "grid"}, {"List", "list"}]} />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :hint, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values:
      ~w(checkbox switch segmented color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox and switch inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"

  attr :options, :list,
    doc: "options for select and segmented: a list of {label, value} or values"

  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "extra classes for the control"
  attr :wrapper_class, :any, default: nil

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step autofocus)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class={["space-y-1", @wrapper_class]}>
      <label for={@id} class="group inline-flex cursor-pointer items-start gap-2.5 text-sm">
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="relative mt-0.5 inline-flex">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={[
              "peer size-4 cursor-pointer appearance-none rounded-xs border border-border-strong bg-surface shadow-xs",
              "transition-colors duration-(--duration-fast) checked:border-accent checked:bg-accent",
              "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring",
              "group-hover:border-fg-faint disabled:cursor-not-allowed disabled:opacity-50",
              @class
            ]}
            {@rest}
          />
          <.icon
            name="hero-check-micro"
            class="pointer-events-none absolute inset-0 size-4 scale-75 text-on-accent opacity-0 transition duration-(--duration-fast) ease-(--ease-spring) peer-checked:scale-100 peer-checked:opacity-100"
          />
        </span>
        <span :if={@label || @hint} class="flex flex-col">
          <span :if={@label} class="font-medium text-fg">{@label}</span>
          <span :if={@hint} class="text-xs text-fg-subtle">{@hint}</span>
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "switch"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class={["space-y-1", @wrapper_class]}>
      <label for={@id} class="group flex cursor-pointer items-center justify-between gap-4 text-sm">
        <span :if={@label || @hint} class="flex flex-col">
          <span :if={@label} class="font-medium text-fg">{@label}</span>
          <span :if={@hint} class="text-xs text-fg-subtle">{@hint}</span>
        </span>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="relative inline-flex shrink-0">
          <input
            type="checkbox"
            role="switch"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={[
              "peer h-5 w-8.5 cursor-pointer appearance-none rounded-full bg-active",
              "shadow-[inset_0_0_0_1px_var(--color-border-strong)]",
              "transition-colors duration-(--duration-base) ease-(--ease-out)",
              "checked:bg-accent checked:shadow-none",
              "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring",
              "disabled:cursor-not-allowed disabled:opacity-50",
              @class
            ]}
            {@rest}
          />
          <span class="pointer-events-none absolute top-0.5 left-0.5 size-4 rounded-full bg-white shadow-sm transition-transform duration-(--duration-base) ease-(--ease-spring) peer-checked:translate-x-3.5" />
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "segmented"} = assigns) do
    assigns = assign(assigns, :options, normalize_options(assigns.options))

    ~H"""
    <div class={["space-y-1.5", @wrapper_class]}>
      <span :if={@label} class="block text-sm font-medium text-fg">{@label}</span>
      <div
        role="radiogroup"
        id={@id}
        aria-label={@label}
        class={[
          "inline-flex rounded-md bg-hover p-0.5 shadow-[inset_0_0_0_1px_var(--color-border)]",
          @class
        ]}
      >
        <label
          :for={{label, value} <- @options}
          class={[
            "relative flex h-7 cursor-pointer select-none items-center gap-1.5 rounded-[5px] px-2.5 text-sm text-fg-muted",
            "transition-[background-color,color,box-shadow] duration-(--duration-fast) ease-(--ease-out)",
            "hover:text-fg has-checked:bg-surface has-checked:text-fg has-checked:shadow-sm",
            "has-focus-visible:outline-2 has-focus-visible:outline-ring"
          ]}
        >
          <input
            type="radio"
            name={@name}
            value={value}
            checked={to_string(value) == to_string(@value)}
            class="sr-only"
            {@rest}
          />
          {label}
        </label>
      </div>
      <p :if={@hint} class="text-xs text-fg-subtle">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class={["space-y-1.5", @wrapper_class]}>
      <label :if={@label} for={@id} class="block text-sm font-medium text-fg">{@label}</label>
      <div class="relative">
        <select
          id={@id}
          name={@name}
          class={[
            control_base(),
            control_state(@errors != []),
            "h-8 cursor-pointer appearance-none pr-8 pl-2.5",
            @class
          ]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
        <.icon
          name="hero-chevron-up-down-mini"
          class="pointer-events-none absolute top-1/2 right-2 size-4 -translate-y-1/2 text-fg-subtle"
        />
      </div>
      <p :if={@hint} class="text-xs text-fg-subtle">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class={["space-y-1.5", @wrapper_class]}>
      <label :if={@label} for={@id} class="block text-sm font-medium text-fg">{@label}</label>
      <textarea
        id={@id}
        name={@name}
        class={[
          control_base(),
          control_state(@errors != []),
          "min-h-20 px-2.5 py-1.5 leading-relaxed field-sizing-content",
          @class
        ]}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <p :if={@hint} class="text-xs text-fg-subtle">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class={["space-y-1.5", @wrapper_class]}>
      <label :if={@label} for={@id} class="block text-sm font-medium text-fg">{@label}</label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[control_base(), control_state(@errors != []), "h-8 px-2.5", @class]}
        {@rest}
      />
      <p :if={@hint} class="text-xs text-fg-subtle">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  defp normalize_options(options) do
    Enum.map(options, fn
      {label, value} -> {label, value}
      value -> {to_string(value), value}
    end)
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="flex items-center gap-1.5 text-xs text-danger-fg">
      <.icon name="hero-exclamation-circle-mini" class="size-3.5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  A search field with a leading icon. Pressing `/` focuses it when
  `shortcut` is set.
  """
  attr :id, :string, required: true
  attr :name, :string, default: "query"
  attr :value, :string, default: ""
  attr :placeholder, :string, default: nil
  attr :shortcut, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(phx-debounce autocomplete form)

  def search_input(assigns) do
    ~H"""
    <div class={["relative", @class]}>
      <.icon
        name="hero-magnifying-glass-mini"
        class="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-fg-subtle"
      />
      <input
        type="search"
        id={@id}
        name={@name}
        value={@value}
        placeholder={@placeholder || gettext("Search")}
        autocomplete="off"
        data-shortcut={@shortcut && "/"}
        class={[
          control_base(),
          control_state(false),
          "h-8 pr-8 pl-8 [&::-webkit-search-cancel-button]:hidden"
        ]}
        {@rest}
      />
      <.kbd :if={@shortcut} class="pointer-events-none absolute top-1/2 right-2 -translate-y-1/2">
        /
      </.kbd>
    </div>
    """
  end

  ## Typography and layout

  @doc """
  Renders a page header with title, optional subtitle and actions.
  """
  attr :class, :any, default: nil
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={["flex flex-wrap items-end justify-between gap-x-6 gap-y-3", @class]}>
      <div class="min-w-0">
        <h1 class="truncate text-2xl font-semibold text-fg">{render_slot(@inner_block)}</h1>
        <p :if={@subtitle != []} class="mt-1 text-base text-fg-muted">{render_slot(@subtitle)}</p>
      </div>
      <div :if={@actions != []} class="flex shrink-0 items-center gap-2">
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  @doc """
  A keyboard key. Use `"mod"` for ⌘ on macOS and Ctrl elsewhere.

      <.kbd>mod</.kbd><.kbd>K</.kbd>
  """
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def kbd(assigns) do
    ~H"""
    <kbd class={[
      "inline-flex h-5 min-w-5 items-center justify-center rounded-xs border border-border-strong bg-surface px-1",
      "font-sans text-2xs font-medium text-fg-muted shadow-[0_1px_0_var(--color-border-strong)]",
      @class
    ]}>
      {render_kbd(render_slot(@inner_block))}
    </kbd>
    """
  end

  defp render_kbd(content) do
    case content |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary() |> String.trim() do
      "mod" ->
        assigns = %{}

        ~H"""
        <span class="hidden [[data-platform=mac]_&]:inline">⌘</span><span class="[[data-platform=mac]_&]:hidden">Ctrl</span>
        """

      other ->
        other
    end
  end

  @badge_tones %{
    "neutral" => "bg-hover text-fg-muted shadow-[inset_0_0_0_1px_var(--color-border)]",
    "accent" => "bg-accent-soft text-accent-fg",
    "success" => "bg-success-soft text-success-fg",
    "warning" => "bg-warning-soft text-warning-fg",
    "danger" => "bg-danger-soft text-danger-fg"
  }

  @doc """
  A small status label. `dot` adds a leading dot; `pulse` makes it breathe
  (for live states like "reading now").
  """
  attr :tone, :string, default: "neutral", values: ~w(neutral accent success warning danger)
  attr :dot, :boolean, default: false
  attr :pulse, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def badge(assigns) do
    assigns = assign(assigns, :tone_class, Map.fetch!(@badge_tones, assigns.tone))

    ~H"""
    <span
      class={[
        "inline-flex h-5 items-center gap-1.5 whitespace-nowrap rounded-sm px-1.5 text-xs font-medium",
        @tone_class,
        @class
      ]}
      {@rest}
    >
      <span
        :if={@dot or @pulse}
        class={["size-1.5 rounded-full bg-current", @pulse && "animate-pulse-dot"]}
      />
      {render_slot(@inner_block)}
    </span>
    """
  end

  @avatar_colors %{
    "slate" => "bg-avatar-slate/15 text-avatar-slate",
    "red" => "bg-avatar-red/15 text-avatar-red",
    "orange" => "bg-avatar-orange/15 text-avatar-orange",
    "amber" => "bg-avatar-amber/18 text-avatar-amber",
    "green" => "bg-avatar-green/15 text-avatar-green",
    "teal" => "bg-avatar-teal/15 text-avatar-teal",
    "blue" => "bg-avatar-blue/15 text-avatar-blue",
    "indigo" => "bg-avatar-indigo/15 text-avatar-indigo",
    "violet" => "bg-avatar-violet/15 text-avatar-violet",
    "pink" => "bg-avatar-pink/15 text-avatar-pink"
  }

  @avatar_sizes %{
    "xs" => "size-5 text-[0.5625rem]",
    "sm" => "size-6 text-2xs",
    "md" => "size-8 text-xs",
    "lg" => "size-10 text-sm",
    "xl" => "size-14 text-lg"
  }

  @doc "The avatar colour names, for pickers."
  def avatar_colors, do: Map.keys(@avatar_colors) |> Enum.sort()

  @doc """
  An initials avatar.

      <.avatar name="Ana García" color="teal" />
  """
  attr :name, :string, required: true
  attr :color, :string, default: "slate"
  attr :size, :string, default: "md", values: ~w(xs sm md lg xl)
  attr :class, :any, default: nil
  attr :rest, :global

  def avatar(assigns) do
    assigns =
      assign(assigns,
        initials: initials(assigns.name),
        color_class: Map.get(@avatar_colors, assigns.color, @avatar_colors["slate"]),
        size_class: Map.fetch!(@avatar_sizes, assigns.size)
      )

    ~H"""
    <span
      class={[
        "inline-flex shrink-0 select-none items-center justify-center rounded-full font-semibold tracking-wide",
        @color_class,
        @size_class,
        @class
      ]}
      title={@name}
      {@rest}
    >
      {@initials}
    </span>
    """
  end

  @doc false
  def initials(name) when is_binary(name) do
    name
    |> String.split("@")
    |> List.first()
    |> String.split(~r/[\s._-]+/u, trim: true)
    |> case do
      [] -> "?"
      [one] -> one |> String.slice(0, 2)
      [first | rest] -> String.first(first) <> String.first(List.last(rest))
    end
    |> String.upcase()
  end

  def initials(_), do: "?"

  @doc """
  A card surface. Optional header with title and actions.
  """
  attr :id, :string, default: nil
  attr :title, :string, default: nil
  attr :description, :string, default: nil
  attr :padded, :boolean, default: true
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true
  slot :actions
  slot :footer

  def card(assigns) do
    ~H"""
    <section
      id={@id}
      class={["rounded-lg border border-border bg-surface shadow-xs", @class]}
      {@rest}
    >
      <header
        :if={@title || @actions != []}
        class="flex items-start justify-between gap-4 border-b border-border px-4 py-3"
      >
        <div class="min-w-0">
          <h2 :if={@title} class="text-md font-semibold text-fg">{@title}</h2>
          <p :if={@description} class="mt-0.5 text-sm text-fg-muted">{@description}</p>
        </div>
        <div :if={@actions != []} class="flex shrink-0 items-center gap-2">
          {render_slot(@actions)}
        </div>
      </header>
      <div class={@padded && "p-4"}>{render_slot(@inner_block)}</div>
      <footer
        :if={@footer != []}
        class="flex items-center justify-end gap-2 rounded-b-lg border-t border-border bg-inset px-4 py-3"
      >
        {render_slot(@footer)}
      </footer>
    </section>
    """
  end

  @doc """
  An empty state: icon, title, a line of help and an optional action.
  """
  attr :icon, :string, default: "hero-inbox"
  attr :title, :string, required: true
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block
  slot :actions

  def empty_state(assigns) do
    ~H"""
    <div
      class={["flex flex-col items-center justify-center px-6 py-14 text-center", @class]}
      {@rest}
    >
      <div class="mb-4 flex size-11 items-center justify-center rounded-xl border border-border bg-surface text-fg-subtle shadow-sm">
        <.icon name={@icon} class="size-5" />
      </div>
      <h3 class="text-md font-semibold text-fg">{@title}</h3>
      <p :if={@inner_block != []} class="mt-1 max-w-sm text-sm text-fg-muted">
        {render_slot(@inner_block)}
      </p>
      <div :if={@actions != []} class="mt-5 flex items-center gap-2">{render_slot(@actions)}</div>
    </div>
    """
  end

  @doc """
  A loading placeholder. Size it with classes.

      <.skeleton class="h-4 w-40" />
  """
  attr :class, :any, default: "h-4 w-full"
  attr :rest, :global

  def skeleton(assigns) do
    ~H"""
    <div class={["ui-skeleton", @class]} aria-hidden="true" {@rest} />
    """
  end

  @doc """
  Tabs as links (usually `patch`), with an animated underline on the active one.

      <.tabs id="doc-tabs">
        <:tab patch={~p"/documents/1"} active={@live_action == :show}>Overview</:tab>
      </.tabs>
  """
  attr :id, :string, required: true
  attr :class, :any, default: nil

  slot :tab, required: true do
    attr :patch, :string
    attr :navigate, :string
    attr :active, :boolean
    attr :count, :integer
    attr :id, :string
  end

  def tabs(assigns) do
    ~H"""
    <nav id={@id} class={["flex items-center gap-1 border-b border-border", @class]} role="tablist">
      <.link
        :for={tab <- @tab}
        id={tab[:id]}
        patch={tab[:patch]}
        navigate={tab[:navigate]}
        role="tab"
        aria-selected={to_string(!!tab[:active])}
        class={[
          "relative -mb-px flex h-9 shrink-0 items-center gap-1.5 whitespace-nowrap px-2.5 text-sm font-medium transition-colors duration-(--duration-fast)",
          "after:absolute after:inset-x-2 after:bottom-0 after:h-0.5 after:rounded-full after:transition-[background-color,transform] after:duration-(--duration-base) after:ease-(--ease-out)",
          if(tab[:active],
            do: "text-fg after:scale-x-100 after:bg-fg",
            else: "text-fg-muted after:scale-x-50 after:bg-transparent hover:text-fg"
          )
        ]}
      >
        {render_slot(tab)}
        <span
          :if={tab[:count]}
          class="rounded-sm bg-hover px-1 text-2xs font-medium text-fg-subtle tabular-nums"
        >
          {tab[:count]}
        </span>
      </.link>
    </nav>
    """
  end

  @doc """
  A segmented control for view switches that are not form fields (e.g. grid
  or list). Each item is a link or button with its own attributes.

      <.segmented id="view">
        <:item patch={~p"/documents?view=grid"} active={@view == "grid"} icon="hero-squares-2x2-mini" label="Grid" />
      </.segmented>
  """
  attr :id, :string, required: true
  attr :class, :any, default: nil

  # Item keys: active, icon, label, icon_only, plus any link or phx-* attribute.
  slot :item, required: true, validate_attrs: false

  def segmented(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "inline-flex rounded-md bg-hover p-0.5 shadow-[inset_0_0_0_1px_var(--color-border)]",
        @class
      ]}
    >
      <.link
        :for={item <- @item}
        aria-pressed={to_string(!!item[:active])}
        aria-label={item[:label]}
        title={item[:icon_only] && item[:label]}
        class={[
          "flex h-7 cursor-pointer select-none items-center gap-1.5 rounded-[5px] px-2 text-sm",
          "transition-[background-color,color,box-shadow,transform] duration-(--duration-fast) ease-(--ease-out) active:scale-[0.96]",
          if(item[:active],
            do: "bg-surface text-fg shadow-sm",
            else: "text-fg-muted hover:text-fg"
          )
        ]}
        {Phoenix.Component.assigns_to_attributes(item, [:active, :icon, :label, :icon_only])}
      >
        <.icon :if={item[:icon]} name={item[:icon]} class="size-4" />
        <span :if={!item[:icon_only]}>{item[:label] || render_slot(item)}</span>
      </.link>
    </div>
    """
  end

  @doc """
  Renders a table. Works with lists and streams.

      <.table id="users" rows={@streams.users}>
        <:col :let={{_id, user}} label="Name">{user.name}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"
  attr :row_class, :any, default: nil

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  attr :class, :any, default: nil

  slot :col, required: true do
    attr :label, :string
    attr :class, :string
    attr :numeric, :boolean
  end

  slot :action, doc: "the slot for showing user actions in the last table column"
  slot :empty, doc: "shown when there are no rows (as the only child of the body)"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class={[
      "overflow-x-auto rounded-lg border border-border bg-surface shadow-xs",
      @class
    ]}>
      <table class="w-full border-collapse text-sm">
        <thead>
          <tr class="border-b border-border bg-inset/60">
            <th
              :for={col <- @col}
              class={[
                "h-9 px-3 text-left text-xs font-medium whitespace-nowrap text-fg-subtle first:pl-4",
                col[:numeric] && "text-right"
              ]}
            >
              {col[:label]}
            </th>
            <th :if={@action != []} class="w-0 pr-3">
              <span class="sr-only">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
          <tr :if={@empty != []} id={"#{@id}-empty"} class="hidden only:table-row">
            <td colspan={length(@col) + if(@action != [], do: 1, else: 0)}>
              {render_slot(@empty)}
            </td>
          </tr>
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class={[
              "ui-enter-row group border-b border-border transition-colors duration-(--duration-fast) last:border-b-0 hover:bg-hover/50",
              @row_class && @row_class.(row)
            ]}
          >
            <td
              :for={col <- @col}
              phx-click={@row_click && @row_click.(row)}
              class={[
                "h-11 px-3 align-middle whitespace-nowrap first:pl-4",
                @row_click && "cursor-pointer",
                col[:numeric] && "text-right tabular-nums",
                col[:class]
              ]}
            >
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@action != []} class="w-0 pr-2 text-right whitespace-nowrap">
              <div class="flex items-center justify-end gap-1">
                <%= for action <- @action do %>
                  {render_slot(action, @row_item.(row))}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders a description list.

      <.list>
        <:item title="Title">{@post.title}</:item>
      </.list>
  """
  attr :class, :any, default: nil

  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <dl class={["divide-y divide-border", @class]}>
      <div :for={item <- @item} class="grid grid-cols-3 gap-4 py-2.5 text-sm">
        <dt class="text-fg-muted">{item.title}</dt>
        <dd class="col-span-2 text-fg">{render_slot(item)}</dd>
      </div>
    </dl>
    """
  end

  @progress_tones %{
    "accent" => "bg-accent",
    "success" => "bg-success",
    "warning" => "bg-warning",
    "danger" => "bg-danger",
    "neutral" => "bg-fg-subtle"
  }

  @doc """
  A thin progress bar. `value` is 0..`max`.
  """
  attr :value, :any, required: true
  attr :max, :any, default: 100
  attr :tone, :string, default: "accent", values: ~w(accent success warning danger neutral)
  attr :label, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  def progress(assigns) do
    pct =
      if assigns.max in [0, nil],
        do: 0,
        else: min(100, max(0, assigns.value / assigns.max * 100))

    assigns =
      assign(assigns, pct: Float.round(pct * 1.0, 1), tone_class: @progress_tones[assigns.tone])

    ~H"""
    <div
      role="progressbar"
      aria-valuemin="0"
      aria-valuemax={@max}
      aria-valuenow={@value}
      aria-label={@label}
      class={["h-1.5 w-full overflow-hidden rounded-full bg-active", @class]}
      {@rest}
    >
      <div
        class={[
          "h-full rounded-full transition-[width] duration-(--duration-slow) ease-(--ease-out)",
          @tone_class
        ]}
        style={"width: #{@pct}%"}
      />
    </div>
    """
  end

  @doc """
  A relative time ("3 min ago") with the full local date and time on hover.
  """
  attr :at, :any, required: true
  attr :scope, :any, required: true
  attr :class, :any, default: nil

  def relative_time(assigns) do
    ~H"""
    <time
      :if={@at}
      datetime={DateTime.to_iso8601(@at)}
      title={SwitchboardWeb.Format.datetime(@at, @scope)}
      class={["tabular-nums", @class]}
    >
      {SwitchboardWeb.Format.relative(@at, @scope)}
    </time>
    <span :if={!@at} class={["text-fg-faint", @class]}>{gettext("never")}</span>
    """
  end

  ## JS Commands

  @doc "Shows an element with the standard enter transition."
  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 200,
      transition:
        {"transition-[opacity,transform] ease-(--ease-out) duration-(--duration-base)",
         "opacity-0 translate-y-1 scale-[0.98]", "opacity-100 translate-y-0 scale-100"}
    )
  end

  @doc "Hides an element with the standard exit transition."
  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 120,
      transition:
        {"transition-[opacity,transform] ease-(--ease-in) duration-(--duration-fast)",
         "opacity-100 translate-y-0 scale-100", "opacity-0 translate-y-1 scale-[0.98]"}
    )
  end

  @doc "Copies `text` to the clipboard and shows a toast."
  def copy(js \\ %JS{}, text, message) do
    JS.dispatch(js, "switchboard:copy",
      detail: %{text: text, message: message, failed: gettext("Couldn't copy to the clipboard")}
    )
  end

  @doc "Switches the colour theme on the client (system, light or dark)."
  def set_theme(js \\ %JS{}, theme) do
    JS.dispatch(js, "switchboard:set-theme", detail: %{theme: theme})
  end

  ## Errors

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # Error messages are generated dynamically, so we call Gettext with the
    # backend as first argument. Translations live in the "errors" domain.
    if count = opts[:count] do
      Gettext.dngettext(SwitchboardWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(SwitchboardWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
