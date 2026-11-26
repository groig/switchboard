defmodule SwitchboardWeb.Shell do
  @moduledoc """
  `on_mount` hook for every app LiveView: handles events from the shared shell (the theme
  toggle) and re-renders when admins change the live controls (maintenance banner).
  """
  import Phoenix.LiveView

  alias Switchboard.{Accounts, Controls, Scope}

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket), do: Controls.subscribe()

    {:cont,
     socket
     |> attach_hook(:shell_events, :handle_event, &handle_event/3)
     |> attach_hook(:shell_info, :handle_info, &handle_info/2)}
  end

  defp handle_info(:controls_changed, socket) do
    # The banner reads the controls on render; a no-op assign triggers one. Pages that show
    # controls themselves also get the message.
    view = socket.view

    socket =
      if function_exported?(view, :handle_controls_changed, 1),
        do: view.handle_controls_changed(socket),
        else: Phoenix.Component.update(socket, :current_scope, & &1)

    {:halt, socket}
  end

  defp handle_info(_message, socket), do: {:cont, socket}

  # The theme is applied on the client first; this only persists it.
  defp handle_event("shell:set_theme", %{"theme" => theme}, socket) do
    case socket.assigns[:current_scope] do
      %Scope{user: %{}} = scope when theme in ["system", "light", "dark"] ->
        {:ok, user} = Accounts.update_theme(scope, theme)
        {:halt, Phoenix.Component.assign(socket, :current_scope, %{scope | user: user})}

      _ ->
        {:halt, socket}
    end
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}
end
