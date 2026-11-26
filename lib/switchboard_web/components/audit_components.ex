defmodule SwitchboardWeb.AuditComponents do
  @moduledoc "The audit log list, shared by My activity and the admin audit log."
  use Phoenix.Component
  use Gettext, backend: SwitchboardWeb.Gettext

  import SwitchboardWeb.CoreComponents

  alias SwitchboardWeb.{AuditLabels, Format}

  attr :id, :string, required: true
  attr :events, :any, required: true, doc: "a stream of `Switchboard.Audit.Event`"
  attr :scope, :any, required: true
  attr :show_user, :boolean, default: false

  def audit_list(assigns) do
    ~H"""
    <div class="overflow-hidden rounded-lg border border-border bg-surface">
      <ul id={@id} phx-update="stream" class="divide-y divide-border">
        <li id={"#{@id}-empty"} class="hidden only:block">
          <.empty_state icon="hero-queue-list" title={gettext("Nothing here yet")} />
        </li>
        <li
          :for={{dom_id, event} <- @events}
          id={dom_id}
          class="ui-enter-row grid gap-x-4 gap-y-1 px-4 py-2.5 text-sm sm:grid-cols-[9rem_1fr_auto]"
        >
          <div class="text-fg-subtle tabular-nums">
            <time datetime={DateTime.to_iso8601(event.at)} title={Format.datetime(event.at, @scope)}>
              {Format.relative(event.at, @scope)}
            </time>
          </div>
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
              <span :if={@show_user} class="font-medium text-fg">{event.username || "–"}</span>
              <%= if event.kind == "mcp" do %>
                <code class="rounded-sm bg-inset px-1 py-px font-mono text-xs text-fg">
                  {event.action}
                </code>
              <% else %>
                <span class="text-fg">{AuditLabels.action(event.action)}</span>
              <% end %>
              <span :if={event.client_name} class="truncate text-xs text-fg-subtle">
                {gettext("via %{client}", client: event.client_name)}
              </span>
              <span :for={up <- event.upstreams} class="text-2xs text-fg-faint uppercase">{up}</span>
            </div>
            <div
              :if={event.args != %{}}
              class="mt-0.5 truncate font-mono text-2xs text-fg-subtle"
              title={args_text(event.args)}
            >
              {args_text(event.args)}
            </div>
            <div :if={event.error} class="mt-0.5 text-xs text-danger-fg">{event.error}</div>
          </div>
          <div class="flex items-center gap-2 sm:justify-end">
            <span :if={event.duration_ms} class="text-xs text-fg-subtle tabular-nums">
              {Format.number(event.duration_ms)} ms
            </span>
            <.badge tone={outcome_tone(event.outcome)}>{AuditLabels.outcome(event.outcome)}</.badge>
          </div>
        </li>
      </ul>
    </div>
    """
  end

  defp outcome_tone("ok"), do: "success"
  defp outcome_tone("error"), do: "danger"
  defp outcome_tone(_), do: "warning"

  defp args_text(args) do
    Enum.map_join(args, "  ", fn {k, v} -> "#{k}=#{value_text(v)}" end)
  end

  defp value_text(v) when is_binary(v), do: v
  defp value_text(v), do: Jason.encode!(v)
end
