defmodule SwitchboardWeb.Admin.OnboardingLive do
  @moduledoc """
  Admin: how far each person got on Get started (agent connected, accounts linked, prompts
  tried) and when they were last active, to spot who is stuck without asking. Read-only; the
  data is `Switchboard.Onboarding.overview/0`.
  """
  use SwitchboardWeb, :live_view

  alias Switchboard.Accounts.User
  alias Switchboard.Onboarding

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Onboarding"))
     |> assign(:rows, Onboarding.overview())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:admin_onboarding}>
      <:crumb>{gettext("Admin")}</:crumb>
      <:crumb>{gettext("Onboarding")}</:crumb>
      <Layouts.page_header
        title={gettext("Onboarding")}
        lead={
          gettext(
            "Who got how far on Get started. Someone with no agent call, or nothing tried after a few days, may be stuck."
          )
        }
      />

      <.table id="onboarding" rows={@rows} row_id={&"onboarding-#{&1.user.id}"}>
        <:col :let={row} label={gettext("Person")}>
          <div class="flex items-center gap-2.5">
            <.avatar
              name={User.display_name(row.user)}
              color={User.avatar_color(row.user)}
              size="sm"
            />
            <div class="min-w-0">
              <div class="truncate font-medium text-fg">{User.display_name(row.user)}</div>
              <div class="truncate text-xs text-fg-subtle">@{row.user.username}</div>
            </div>
          </div>
        </:col>
        <:col :let={row} label={gettext("Agent")}>
          <%= if row.agent do %>
            <div class="flex flex-col">
              <span class="flex items-center gap-1.5">
                <.icon
                  name={
                    if(row.activated, do: "hero-check-circle-mini", else: "hero-minus-circle-mini")
                  }
                  class={["size-4", if(row.activated, do: "text-success-fg", else: "text-warning-fg")]}
                />
                <span class="text-fg">{row.agent.client || gettext("Unnamed client")}</span>
              </span>
              <.relative_time at={row.agent.at} scope={@current_scope} class="text-xs text-fg-subtle" />
            </div>
          <% else %>
            <.badge tone="warning">{gettext("Not connected")}</.badge>
          <% end %>
        </:col>
        <:col :let={row} label={gettext("Accounts")}>
          <span class={[
            "tabular-nums",
            if(row.accounts_linked == row.accounts_total, do: "text-success-fg", else: "text-fg")
          ]}>
            {row.accounts_linked}/{row.accounts_total}
          </span>
        </:col>
        <:col :let={row} label={gettext("Prompts tried")}>
          <div class="flex w-28 items-center gap-2">
            <.progress
              value={row.prompts_tried}
              max={row.prompts_total}
              tone={if(row.prompts_tried >= 3, do: "success", else: "accent")}
              label={gettext("Prompts tried")}
            />
            <span class="text-xs text-fg-muted tabular-nums">
              {row.prompts_tried}/{row.prompts_total}
            </span>
          </div>
        </:col>
        <:col :let={row} label={gettext("Last active")}>
          <.relative_time at={last_active(row)} scope={@current_scope} />
        </:col>
        <:empty>
          <.empty_state icon="hero-users" title={gettext("Nobody has signed in yet")} />
        </:empty>
      </.table>
    </Layouts.app>
    """
  end

  # The latest of the last audit row and the last sign-in.
  defp last_active(%{last_active: a, user: %{last_login_at: b}}) do
    [a, b]
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end
end
