defmodule SwitchboardWeb.Admin.ControlsLive do
  @moduledoc "Admin: global read-only mode, maintenance message, per-tool switches and limits."
  use SwitchboardWeb, :live_view

  alias Switchboard.{Controls, Tools}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, gettext("Controls")) |> load()}
  end

  defp load(socket) do
    socket
    |> assign(:global, Controls.global())
    |> assign(:global_form, to_form(Controls.change_global()))
    |> assign(:tools, Tools.all())
    |> assign(:tool_controls, Controls.tool_controls())
  end

  @doc false
  def handle_controls_changed(socket), do: load(socket)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:admin_controls}>
      <:crumb>{gettext("Admin")}</:crumb>
      <:crumb>{gettext("Controls")}</:crumb>
      <Layouts.page_header
        title={gettext("Controls")}
        lead={gettext("Applied to the next tool call, for everyone. Every change is audited.")}
      />

      <.card title={gettext("Global")} id="global-controls" class="mb-8">
        <.form for={@global_form} id="global-form" phx-submit="save_global" class="space-y-4">
          <.input
            field={@global_form[:read_only]}
            type="switch"
            label={gettext("Read-only mode")}
            hint={gettext("Refuses every tool that changes data. Reads keep working.")}
          />
          <.input
            field={@global_form[:watches_paused]}
            type="switch"
            label={gettext("Pause watches")}
            hint={
              gettext(
                "No new watches, no checks and no notices until switched back. Waiting notices are sent then."
              )
            }
          />
          <.input
            field={@global_form[:maintenance_message]}
            label={gettext("Maintenance message")}
            hint={
              gettext(
                "Shown as a banner here and at the top of every tool result. Leave empty to clear."
              )
            }
            maxlength="200"
          />
          <div class="flex justify-end">
            <.button type="submit" variant="primary" id="global-save">{gettext("Save")}</.button>
          </div>
        </.form>
      </.card>

      <h2 class="mb-3 text-md font-semibold text-fg">{gettext("Tools")}</h2>
      <.table id="tool-controls" rows={@tools} row_id={&"tool-#{&1.name()}"}>
        <:col :let={tool} label={gettext("Tool")}>
          <code class="font-mono text-xs text-fg">{tool.name()}</code>
          <.badge :if={!tool.annotations()[:read_only]} tone="warning" class="ml-2">
            {gettext("write")}
          </.badge>
        </:col>
        <:col :let={tool} label={gettext("Enabled")}>
          <button
            type="button"
            role="switch"
            id={"toggle-#{tool.name()}"}
            aria-checked={to_string(enabled?(@tool_controls, tool))}
            phx-click="toggle_tool"
            phx-value-tool={tool.name()}
            class={[
              "relative inline-flex h-5 w-9 cursor-pointer items-center rounded-full transition-colors duration-(--duration-fast)",
              if(enabled?(@tool_controls, tool), do: "bg-accent", else: "bg-active")
            ]}
          >
            <span class={[
              "inline-block size-4 rounded-full bg-white shadow-sm transition-transform duration-(--duration-fast) ease-(--ease-out)",
              if(enabled?(@tool_controls, tool), do: "translate-x-4.5", else: "translate-x-0.5")
            ]} />
            <span class="sr-only">{gettext("Enabled")}</span>
          </button>
        </:col>
        <:col :let={tool} label={gettext("Calls per person per minute")}>
          <.form
            for={%{}}
            as={:limit}
            id={"limit-#{tool.name()}"}
            phx-submit="set_limit"
            class="flex items-center gap-2"
          >
            <input type="hidden" name="tool" value={tool.name()} />
            <input
              type="number"
              name="rate_limit"
              min="1"
              max="10000"
              value={Controls.rate_limit(tool)}
              class="h-7 w-20 rounded-md border border-border bg-surface px-2 text-sm text-fg tabular-nums shadow-xs focus:border-accent focus:outline-none"
            />
            <.button type="submit" size="xs">{gettext("Set")}</.button>
            <span
              :if={custom_limit?(@tool_controls, tool)}
              class="text-2xs text-fg-subtle"
            >
              {gettext("default %{n}", n: Controls.default_rate_limit(tool))}
            </span>
          </.form>
        </:col>
        <:action :let={tool}>
          <.button
            :if={Map.has_key?(@tool_controls, tool.name())}
            size="xs"
            variant="ghost"
            phx-click="reset_tool"
            phx-value-tool={tool.name()}
          >
            {gettext("Reset")}
          </.button>
        </:action>
      </.table>
    </Layouts.app>
    """
  end

  defp enabled?(controls, tool), do: Map.get(controls, tool.name(), %{enabled: true}).enabled

  defp custom_limit?(controls, tool),
    do: match?(%{rate_limit: n} when is_integer(n), Map.get(controls, tool.name()))

  @impl true
  def handle_event("save_global", %{"global" => params}, socket) do
    case Controls.update_global(socket.assigns.current_scope, params) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, gettext("Controls saved.")) |> load()}
      {:error, changeset} -> {:noreply, assign(socket, :global_form, to_form(changeset))}
    end
  end

  def handle_event("toggle_tool", %{"tool" => name}, socket) do
    {:ok, mod} = Tools.fetch(name)
    enabled = not enabled?(socket.assigns.tool_controls, mod)
    {:ok, _} = Controls.update_tool(socket.assigns.current_scope, name, %{enabled: enabled})
    {:noreply, load(socket)}
  end

  def handle_event("set_limit", %{"tool" => name, "rate_limit" => limit}, socket) do
    case Controls.update_tool(socket.assigns.current_scope, name, %{rate_limit: limit}) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, gettext("Limit saved.")) |> load()}
      _ -> {:noreply, put_flash(socket, :error, gettext("Use a number between 1 and 10000."))}
    end
  end

  def handle_event("reset_tool", %{"tool" => name}, socket) do
    :ok = Controls.reset_tool(socket.assigns.current_scope, name)
    {:noreply, load(socket)}
  end
end
