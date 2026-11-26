defmodule SwitchboardWeb.WatchesLive do
  @moduledoc "My watches: active and recent watches, what each waits for, and a cancel button."
  use SwitchboardWeb, :live_view

  alias Switchboard.Watches
  alias Switchboard.Watches.Watch
  alias SwitchboardWeb.Format

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, gettext("My watches")) |> load()}
  end

  defp load(socket) do
    user = socket.assigns.current_scope.user
    watches = Watches.list(user)

    socket
    |> assign(:watches, watches)
    |> assign(:active, Enum.count(watches, &(&1.status == "active")))
    |> assign(:max, Watches.max_active())
    |> assign(:paused?, Switchboard.Controls.watches_paused?())
  end

  @doc false
  def handle_controls_changed(socket), do: load(socket)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:watches}>
      <:crumb>{gettext("My watches")}</:crumb>
      <Layouts.page_header
        title={gettext("My watches")}
        lead={
          gettext(
            "Ask your agent to watch CI, a task or a release, and Switchboard sends you a Rocket.Chat DM when it finishes. Only you get the notices."
          )
        }
      />

      <div
        :if={@paused?}
        id="watches-paused"
        class="mb-4 rounded-lg border border-border bg-warning-soft px-4 py-3 text-sm text-warning-fg"
      >
        {gettext("Watches are paused by an administrator: no checks and no notices for now.")}
      </div>

      <p id="watches-count" class="mb-3 text-sm text-fg-muted tabular-nums">
        {gettext("%{active} active of %{max}", active: @active, max: @max)}
      </p>

      <.table id="watches" rows={@watches} row_id={&"watch-#{&1.id}"}>
        <:col :let={watch} label={gettext("Watching")}>
          <div class="flex items-center gap-2">
            <.badge tone="neutral">{kind(watch)}</.badge>
            <span class="font-medium text-fg">{Watch.label(watch)}</span>
          </div>
        </:col>
        <:col :let={watch} label={gettext("Waits for")}>
          <span class="text-fg-muted">{waits_for(watch)}</span>
        </:col>
        <:col :let={watch} label={gettext("Status")}>
          <.badge tone={tone(watch)} dot pulse={watch.status == "active"}>{outcome(watch)}</.badge>
        </:col>
        <:col :let={watch} label={gettext("Expires / ended")}>
          <span class="text-fg-muted tabular-nums">
            {Format.datetime(
              if(watch.status == "active", do: watch.expires_at, else: watch.ended_at),
              @current_scope
            )}
          </span>
        </:col>
        <:action :let={watch}>
          <.button
            :if={watch.status == "active"}
            id={"cancel-watch-#{watch.id}"}
            size="sm"
            phx-click="cancel"
            phx-value-id={watch.id}
            data-confirm={gettext("Cancel this watch? No notice will be sent.")}
          >
            {gettext("Cancel")}
          </.button>
        </:action>
        <:empty>
          <.empty_state icon="hero-bell-alert" title={gettext("No watches")}>
            {gettext(
              "Try \"DM me when CI on my PR finishes\" or \"tell me when DEMO-12 ships\" in your agent."
            )}
            <:actions>
              <.button id="watches-start" size="sm" navigate={~p"/start"}>
                {gettext("More things to try")}
              </.button>
            </:actions>
          </.empty_state>
        </:empty>
      </.table>
    </Layouts.app>
    """
  end

  defp kind(%Watch{kind: "ci"}), do: gettext("CI")
  defp kind(%Watch{kind: "task"}), do: gettext("Task")
  defp kind(%Watch{kind: "release"}), do: gettext("Release")

  defp waits_for(%Watch{kind: "ci", options: o}) do
    base = if o["next_run"], do: gettext("The next CI run"), else: gettext("CI to finish")
    if o["only_on_failure"], do: gettext("%{what}, only if it fails", what: base), else: base
  end

  defp waits_for(%Watch{kind: "task", options: %{"until" => "done"}}), do: gettext("Done")
  defp waits_for(%Watch{kind: "task", options: %{"until" => "released"}}), do: gettext("Released")
  defp waits_for(%Watch{kind: "task"}), do: gettext("Any change")

  defp waits_for(%Watch{kind: "release", options: o}),
    do:
      if(o["health"],
        do: gettext("Next release and its 24 h health"),
        else: gettext("Next release")
      )

  defp outcome(%Watch{status: "active", last_state: %{"phase" => "health"}}),
    do: gettext("Waiting for health")

  defp outcome(%Watch{status: "active"}), do: gettext("Active")
  defp outcome(%Watch{status: "cancelled"}), do: gettext("Cancelled")

  defp outcome(%Watch{end_reason: reason}) do
    case reason do
      "notified" -> gettext("Notified")
      "succeeded_quietly" -> gettext("Passed (no notice)")
      "timed_out" -> gettext("Expired")
      "connection_missing" -> gettext("Stopped: connection missing")
      "connection_rejected" -> gettext("Stopped: key rejected")
      "access_lost" -> gettext("Stopped: no access")
      _ -> gettext("Ended")
    end
  end

  defp tone(%Watch{status: "active"}), do: "accent"
  defp tone(%Watch{end_reason: "notified"}), do: "success"
  defp tone(%Watch{end_reason: "succeeded_quietly"}), do: "success"
  defp tone(%Watch{status: "cancelled"}), do: "neutral"
  defp tone(%Watch{end_reason: "timed_out"}), do: "neutral"
  defp tone(_), do: "warning"

  @impl true
  def handle_event("cancel", %{"id" => id}, socket) do
    case Watches.cancel(socket.assigns.current_scope, id, via: :web) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, gettext("Watch cancelled.")) |> load()}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, gettext("That watch already ended.")) |> load()}
    end
  end
end
