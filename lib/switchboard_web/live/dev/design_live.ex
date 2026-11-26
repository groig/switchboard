defmodule SwitchboardWeb.Dev.DesignLive do
  @moduledoc """
  The style guide at /dev/design: every token and component, in both themes.
  It is how we review the design, so keep it up to date when you add or change
  a component.

  Dev-only tool: its demo copy is English and intentionally not translated.
  """
  use SwitchboardWeb, :live_view
  on_mount SwitchboardWeb.AdminNetwork

  @surfaces ~w(canvas sidebar surface raised inset hover active)
  @text ~w(fg fg-muted fg-subtle fg-faint)
  @lines ~w(border border-strong ring)
  @accent ~w(accent accent-hover accent-soft accent-fg on-accent)
  @semantic ~w(success success-soft success-fg warning warning-soft warning-fg danger danger-soft danger-fg)
  @avatar ~w(slate red orange amber green teal blue indigo violet pink)
  @type_scale ~w(3xl 2xl xl lg md base sm xs 2xs)
  @radii ~w(xs sm md lg xl)
  @shadows ~w(xs sm md lg xl)

  @sections [
    {"tokens", "Tokens"},
    {"type", "Typography"},
    {"motion", "Motion"},
    {"buttons", "Buttons"},
    {"forms", "Forms"},
    {"overlays", "Overlays"},
    {"display", "Display"},
    {"data", "Data"}
  ]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} width="wide">
      <:crumb>Dev</:crumb>
      <:crumb>Design system</:crumb>
      <:actions>
        <Layouts.theme_toggle id="design-theme" />
      </:actions>

      <.header class="mb-6">
        Design system
        <:subtitle>
          Tokens and components of Switchboard. Toggle the theme to review both.
        </:subtitle>
      </.header>

      <nav class="sticky top-(--topbar-height) z-10 -mx-1 mb-10 flex gap-1 overflow-x-auto bg-canvas/90 py-2 backdrop-blur">
        <a
          :for={{id, label} <- @sections}
          href={"##{id}"}
          class="rounded-md px-2.5 py-1 text-sm whitespace-nowrap text-fg-muted transition-colors hover:bg-hover hover:text-fg"
        >
          {label}
        </a>
      </nav>

      <div class="space-y-16">
        <%!-- Tokens --%>
        <.section
          id="tokens"
          title="Tokens"
          lead="CSS custom properties in @theme (app.css). Light values by default, redefined under [data-theme=dark]."
        >
          <.swatches title="Surfaces" names={@surfaces} />
          <.swatches title="Text" names={@text} text />
          <.swatches title="Lines" names={@lines} />
          <.swatches title="Accent" names={@accent} />
          <.swatches title="Semantic" names={@semantic} />
          <.swatches title="Avatar hues" names={Enum.map(@avatar, &"avatar-#{&1}")} />

          <div class="grid gap-6 md:grid-cols-2">
            <div>
              <h3 class="mb-3 text-sm font-medium text-fg-muted">Radii</h3>
              <div class="flex items-end gap-3">
                <div :for={r <- @radii} class="text-center">
                  <div
                    class="size-14 border border-border-strong bg-surface shadow-xs"
                    style={"border-radius: var(--radius-#{r})"}
                  />
                  <p class="mt-1.5 font-mono text-2xs text-fg-subtle">{r}</p>
                </div>
              </div>
            </div>
            <div>
              <h3 class="mb-3 text-sm font-medium text-fg-muted">Shadows</h3>
              <div class="flex items-end gap-4">
                <div :for={s <- @shadows} class="text-center">
                  <div
                    class="size-14 rounded-lg bg-raised"
                    style={"box-shadow: var(--shadow-#{s})"}
                  />
                  <p class="mt-1.5 font-mono text-2xs text-fg-subtle">{s}</p>
                </div>
              </div>
            </div>
          </div>

          <div>
            <h3 class="mb-3 text-sm font-medium text-fg-muted">Spacing (4 px base)</h3>
            <div class="flex items-end gap-2">
              <div :for={n <- [1, 2, 3, 4, 6, 8, 10, 12, 16]} class="text-center">
                <div
                  class="bg-accent-soft"
                  style={"width: calc(var(--spacing) * #{n}); height: calc(var(--spacing) * #{n})"}
                />
                <p class="mt-1.5 font-mono text-2xs text-fg-subtle">{n}</p>
              </div>
            </div>
          </div>
        </.section>

        <%!-- Typography --%>
        <.section
          id="type"
          title="Typography"
          lead="Inter (self-hosted, variable) for UI; JetBrains Mono for ids. Tabular numbers for analytics."
        >
          <div class="divide-y divide-border rounded-lg border border-border bg-surface">
            <div :for={size <- @type_scale} class="flex items-baseline gap-6 px-4 py-3">
              <span class="w-12 shrink-0 font-mono text-2xs text-fg-subtle">{size}</span>
              <span
                class="truncate text-fg"
                style={"font-size: var(--text-#{size}); line-height: var(--text-#{size}--line-height)"}
              >
                Who read the Q3 report, and for how long
              </span>
            </div>
          </div>
          <div class="grid gap-4 md:grid-cols-3">
            <.card title="Weights">
              <p class="font-normal">Regular 400</p>
              <p class="font-medium">Medium 500</p>
              <p class="font-semibold">Semibold 600</p>
            </.card>
            <.card title="Tabular numbers">
              <p class="text-xl font-semibold tabular-nums">1,204 · 3m 07s · 87%</p>
              <p class="text-xl font-semibold tabular-nums">9,811 · 0m 41s · 12%</p>
            </.card>
            <.card title="Mono">
              <p class="font-mono text-sm">slug: k7Qe-29fHz</p>
              <p class="font-mono text-sm text-fg-muted">id: 0f3c9a1e</p>
            </.card>
          </div>
        </.section>

        <%!-- Motion --%>
        <.section
          id="motion"
          title="Motion"
          lead="Durations 120 / 200 / 320 ms with ease-out, ease-in, ease-in-out and spring. Zeroed under prefers-reduced-motion. Hover the tracks."
        >
          <div class="grid gap-3 md:grid-cols-2">
            <div
              :for={
                {label, duration, ease} <- [
                  {"fast · ease-out", "--duration-fast", "--ease-out"},
                  {"base · ease-out", "--duration-base", "--ease-out"},
                  {"slow · ease-in-out", "--duration-slow", "--ease-in-out"},
                  {"slow · spring", "--duration-slow", "--ease-spring"}
                ]
              }
              class="group rounded-lg border border-border bg-surface p-4"
            >
              <p class="mb-3 font-mono text-xs text-fg-muted">{label}</p>
              <div class="h-2 rounded-full bg-hover">
                <div
                  class="size-2 rounded-full bg-accent transition-transform group-hover:translate-x-[calc(min(30rem,70vw))]"
                  style={"transition-duration: var(#{duration}); transition-timing-function: var(#{ease})"}
                />
              </div>
            </div>
          </div>
        </.section>

        <%!-- Buttons --%>
        <.section
          id="buttons"
          title="Buttons"
          lead="Every button has a pressed state (scale 0.97). Loading shows a shimmer, never a spinner."
        >
          <div :for={size <- ~w(lg md sm xs)} class="flex flex-wrap items-center gap-2">
            <span class="w-8 font-mono text-2xs text-fg-subtle">{size}</span>
            <.button variant="primary" size={size}>Primary</.button>
            <.button variant="secondary" size={size}>Secondary</.button>
            <.button variant="ghost" size={size}>Ghost</.button>
            <.button variant="danger" size={size}>Danger</.button>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <.button variant="primary" icon="hero-arrow-up-tray-mini">Upload</.button>
            <.button icon="hero-link-mini">Copy link</.button>
            <.button variant="ghost" trailing_icon="hero-chevron-down-mini">Sort</.button>
            <.button variant="primary" loading>Saving</.button>
            <.button loading>Loading</.button>
            <.button variant="primary" disabled>Disabled</.button>
            <.button id="demo-click-loading" phx-click="slow">Click (slow event)</.button>
          </div>
          <div class="flex flex-wrap items-center gap-1">
            <.icon_button icon="hero-ellipsis-horizontal-mini" label="More" size="xs" />
            <.icon_button icon="hero-pencil-square-mini" label="Rename" size="sm" />
            <.icon_button icon="hero-link-mini" label="Copy link" size="md" variant="secondary" />
            <.icon_button icon="hero-plus" label="New" size="lg" variant="primary" />
            <.icon_button icon="hero-trash-mini" label="Delete" variant="danger" />
          </div>
        </.section>

        <%!-- Forms --%>
        <.section
          id="forms"
          title="Forms"
          lead="One <.input> for every control. Errors show after interaction."
        >
          <.form
            for={@form}
            id="demo-form"
            phx-change="validate"
            class="grid gap-x-8 gap-y-5 md:grid-cols-2"
          >
            <.input field={@form[:name]} label="Text" placeholder="Client X" hint="A hint helps." />
            <.input field={@form[:email]} type="email" label="With error" />
            <.input
              field={@form[:role]}
              type="select"
              label="Select"
              options={[{"Member", "member"}, {"Admin", "admin"}]}
            />
            <.input field={@form[:expires]} type="date" label="Date" />
            <.input
              field={@form[:notes]}
              type="textarea"
              label="Textarea"
              placeholder="Grows with content"
            />
            <div class="space-y-4">
              <.input field={@form[:agree]} type="checkbox" label="Checkbox" hint="With a hint" />
              <.input
                field={@form[:download]}
                type="switch"
                label="Allow download"
                hint="Off by default"
              />
              <.input
                field={@form[:view]}
                type="segmented"
                label="Segmented (radio)"
                options={[{"Grid", "grid"}, {"List", "list"}, {"Board", "board"}]}
              />
            </div>
            <.search_input id="demo-search" placeholder="Search documents" class="md:col-span-2" />
            <.input name="disabled" value="Read only" label="Disabled" disabled />
          </.form>
          <div>
            <h3 class="mb-3 text-sm font-medium text-fg-muted">Segmented control (links)</h3>
            <.segmented id="demo-segmented">
              <:item patch="#" active icon="hero-squares-2x2-mini" label="Grid" />
              <:item patch="#" icon="hero-list-bullet-mini" label="List" />
            </.segmented>
          </div>
        </.section>

        <%!-- Overlays --%>
        <.section
          id="overlays"
          title="Overlays"
          lead="Native <dialog> for dialogs and sheets (focus trap, Esc, top layer). Dropdowns close on click-away and Esc. Tooltips are pure CSS."
        >
          <div class="flex flex-wrap items-center gap-2">
            <.button phx-click={open_dialog("demo-dialog")}>Open dialog</.button>
            <.button phx-click={open_dialog("demo-sheet")}>Open sheet</.button>
            <.dropdown id="demo-dropdown" align="start">
              <:trigger>
                <.button trailing_icon="hero-chevron-down-mini">Dropdown</.button>
              </:trigger>
              <:item label>Document</:item>
              <:item icon="hero-pencil-square-mini" shortcut="R">Rename</:item>
              <:item icon="hero-link-mini">Copy link</:item>
              <:item separator />
              <:item icon="hero-trash-mini" danger>Delete</:item>
            </.dropdown>
            <.button phx-click="toast" phx-value-kind="info">Server toast</.button>
            <.button phx-click="toast" phx-value-kind="error">Error toast</.button>
            <.button phx-click={copy("https://share.example.com/v/k7Qe29", "Link copied")}>
              Client toast (copy)
            </.button>
            <.tooltip text="Tooltips appear after a beat">
              <.button variant="ghost">Hover me</.button>
            </.tooltip>
          </div>

          <.dialog
            id="demo-dialog"
            title="Share “Q3 Report”"
            description="Create a link for a client or investor."
          >
            <div class="space-y-4">
              <.input name="link_name" value="" label="Link name" placeholder="Client X" />
              <.input name="password" value="" type="password" label="Password (optional)" />
            </div>
            <:footer>
              <.button phx-click={close_dialog("demo-dialog")}>Cancel</.button>
              <.button variant="primary" phx-click={close_dialog("demo-dialog")}>Create link</.button>
            </:footer>
          </.dialog>

          <.sheet id="demo-sheet" title="Link settings" description="Client X · created 3 days ago">
            <div class="space-y-5">
              <.input name="s_name" value="Client X" label="Name" />
              <.input name="s_download" value="false" type="switch" label="Allow download" />
              <.input name="s_watermark" value="true" type="switch" label="Watermark" />
              <.input name="s_email" value="true" type="switch" label="Require email" />
            </div>
            <:footer>
              <.button phx-click={close_dialog("demo-sheet")}>Close</.button>
              <.button variant="primary" phx-click={close_dialog("demo-sheet")}>Save</.button>
            </:footer>
          </.sheet>
        </.section>

        <%!-- Display --%>
        <.section
          id="display"
          title="Display"
          lead="Badges, avatars, keys, cards, empty states, skeletons and tabs."
        >
          <div class="flex flex-wrap items-center gap-2">
            <.badge>Neutral</.badge>
            <.badge tone="accent">Accent</.badge>
            <.badge tone="success" dot>Ready</.badge>
            <.badge tone="warning" dot>Processing</.badge>
            <.badge tone="danger" dot>Failed</.badge>
            <.badge tone="success" pulse>Reading now</.badge>
          </div>
          <div class="flex flex-wrap items-center gap-3">
            <.avatar
              :for={{c, i} <- Enum.with_index(@avatar_colors)}
              name={Enum.at(@names, i)}
              color={c}
            />
            <.avatar name="Ana García" color="teal" size="xs" />
            <.avatar name="Ana García" color="teal" size="sm" />
            <.avatar name="Ana García" color="teal" size="lg" />
            <.avatar name="Ana García" color="teal" size="xl" />
          </div>
          <div class="flex flex-wrap items-center gap-2 text-sm text-fg-muted">
            <.kbd>mod</.kbd><.kbd>K</.kbd>
            <span>·</span>
            <.kbd>G</.kbd>
            then
            <.kbd>D</.kbd>
            <span>·</span>
            <.kbd>?</.kbd>
            <span>·</span>
            <.kbd>esc</.kbd>
          </div>
          <div class="grid gap-4 md:grid-cols-2">
            <.card title="Card with header" description="And a description.">
              <:actions><.button size="sm">Action</.button></:actions>
              <p class="text-sm text-fg-muted">Cards hold related content on a surface.</p>
              <:footer><.button size="sm" variant="primary">Save</.button></:footer>
            </.card>
            <.card>
              <div class="space-y-3">
                <.skeleton class="h-4 w-2/3" />
                <.skeleton class="h-4 w-full" />
                <.skeleton class="h-4 w-5/6" />
                <div class="flex gap-3 pt-2">
                  <.skeleton class="size-10 rounded-full" />
                  <div class="flex-1 space-y-2">
                    <.skeleton class="h-3 w-1/2" /><.skeleton class="h-3 w-1/3" />
                  </div>
                </div>
              </div>
            </.card>
          </div>
          <.tabs id="demo-tabs">
            <:tab patch="#" active>Overview</:tab>
            <:tab patch="#" count={3}>Links</:tab>
            <:tab patch="#" count={128}>Visits</:tab>
            <:tab patch="#">Versions</:tab>
          </.tabs>
          <div class="rounded-lg border border-dashed border-border-strong">
            <.empty_state icon="hero-document-arrow-up" title="No documents yet">
              Upload a PDF, Word or PowerPoint file to start sharing it.
              <:actions>
                <.button variant="primary" icon="hero-arrow-up-tray-mini">Upload</.button>
              </:actions>
            </.empty_state>
          </div>
          <div class="max-w-md space-y-3">
            <.progress value={30} label="Upload" />
            <.progress value={72} tone="success" />
            <.progress value={92} tone="warning" />
          </div>
        </.section>

        <%!-- Data --%>
        <.section
          id="data"
          title="Data"
          lead="Tables (lists or streams), description lists and relative times."
        >
          <.table id="demo-table" rows={@rows}>
            <:col :let={row} label="Viewer">
              <div class="flex items-center gap-2.5">
                <.avatar name={row.name} color={row.color} size="sm" />
                <span class="font-medium">{row.name}</span>
              </div>
            </:col>
            <:col :let={row} label="Link">{row.link}</:col>
            <:col :let={row} label="Time" numeric>{Format.duration(row.seconds)}</:col>
            <:col :let={row} label="Completion" numeric>{Format.percent(row.completion)}</:col>
            <:col :let={row} label="When">
              <.relative_time at={row.at} scope={@current_scope} class="text-fg-muted" />
            </:col>
            <:action>
              <.icon_button icon="hero-ellipsis-horizontal-mini" label="Actions" tooltip={false} />
            </:action>
          </.table>
          <.card>
            <.list>
              <:item title="Pages">24</:item>
              <:item title="Size">{Format.number(4_812_330)} bytes</:item>
              <:item title="Uploaded">{Format.datetime(DateTime.utc_now(), @current_scope)}</:item>
            </.list>
          </.card>
        </.section>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :lead, :string, default: nil
  slot :inner_block, required: true

  defp section(assigns) do
    ~H"""
    <section id={@id} class="scroll-mt-24 space-y-6">
      <div class="border-b border-border pb-3">
        <h2 class="text-xl font-semibold text-fg">{@title}</h2>
        <p :if={@lead} class="mt-1 text-sm text-fg-muted">{@lead}</p>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :title, :string, required: true
  attr :names, :list, required: true
  attr :text, :boolean, default: false

  defp swatches(assigns) do
    ~H"""
    <div>
      <h3 class="mb-3 text-sm font-medium text-fg-muted">{@title}</h3>
      <div class="grid grid-cols-2 gap-3 sm:grid-cols-4 lg:grid-cols-7">
        <div :for={name <- @names} class="overflow-hidden rounded-lg border border-border bg-surface">
          <div
            :if={!@text}
            class="h-12 border-b border-border"
            style={"background: var(--color-#{name})"}
          />
          <div
            :if={@text}
            class="flex h-12 items-center border-b border-border px-3 text-lg font-semibold"
            style={"color: var(--color-#{name})"}
          >
            Aa
          </div>
          <p class="truncate px-2.5 py-1.5 font-mono text-2xs text-fg-muted">{name}</p>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    now = DateTime.utc_now()

    {:ok,
     socket
     |> assign(:page_title, "Design system")
     |> assign(:sections, @sections)
     |> assign(:surfaces, @surfaces)
     |> assign(:text, @text)
     |> assign(:lines, @lines)
     |> assign(:accent, @accent)
     |> assign(:semantic, @semantic)
     |> assign(:avatar, @avatar)
     |> assign(:avatar_colors, @avatar)
     |> assign(:type_scale, @type_scale)
     |> assign(:radii, @radii)
     |> assign(:shadows, @shadows)
     |> assign(:names, ~w(Ana Bruno Carla Diego Elena Fabio Greta Hugo Irene Jorge))
     |> assign(:form, demo_form(%{}))
     |> assign(:rows, [
       %{
         name: "Ana García",
         color: "teal",
         link: "Client X",
         seconds: 412,
         completion: 100,
         at: DateTime.add(now, -120)
       },
       %{
         name: "ben@fund.vc",
         color: "violet",
         link: "Investors",
         seconds: 95,
         completion: 41,
         at: DateTime.add(now, -7200)
       },
       %{
         name: "Carla Ruiz",
         color: "orange",
         link: "Board",
         seconds: 1310,
         completion: 88,
         at: DateTime.add(now, -200_000)
       }
     ])}
  end

  @impl true
  def handle_event("validate", %{"demo" => params}, socket) do
    {:noreply, assign(socket, :form, demo_form(params))}
  end

  def handle_event("toast", %{"kind" => "error"}, socket) do
    {:noreply, put_flash(socket, :error, "The upload failed: file is not a PDF.")}
  end

  def handle_event("toast", _params, socket) do
    {:noreply, put_flash(socket, :info, "Link “Client X” created.")}
  end

  def handle_event("slow", _params, socket) do
    Process.sleep(1200)
    {:noreply, socket}
  end

  defp demo_form(params) do
    types = %{
      name: :string,
      email: :string,
      role: :string,
      expires: :date,
      notes: :string,
      agree: :boolean,
      download: :boolean,
      view: :string
    }

    {%{view: "grid", email: "not-an-email"}, types}
    |> Ecto.Changeset.cast(params, Map.keys(types))
    |> Ecto.Changeset.validate_format(:email, ~r/@/, message: "must have the @ sign")
    |> Map.put(:action, :validate)
    |> to_form(as: :demo)
  end
end
