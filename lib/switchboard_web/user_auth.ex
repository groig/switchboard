defmodule SwitchboardWeb.UserAuth do
  @moduledoc """
  Browser sessions: plugs for controllers and `on_mount` hooks for LiveViews.

  The session holds the user id and the user's `session_version`; an admin's "revoke all" bumps
  the version, which signs the person out of every browser on their next request.
  """
  use SwitchboardWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Switchboard.Accounts
  alias Switchboard.Accounts.User
  alias Switchboard.Scope

  ## Sessions

  @doc "Starts a fresh session for the user and redirects to where they were going."
  def log_in(conn, %User{} = user) do
    return_to = get_session(conn, :return_to)

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(:user_id, user.id)
    |> put_session(:session_version, user.session_version)
    |> put_session(:live_socket_id, live_socket_id(user))
    |> redirect(to: return_to || ~p"/connections")
  end

  def log_out(conn) do
    if live_socket_id = get_session(conn, :live_socket_id) do
      SwitchboardWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn |> configure_session(drop: true) |> redirect(to: ~p"/")
  end

  @doc "Disconnects the user's open LiveViews (after revoking their sessions)."
  def disconnect_sessions(%User{} = user) do
    SwitchboardWeb.Endpoint.broadcast(live_socket_id(user), "disconnect", %{})
  end

  defp live_socket_id(user), do: "users_sessions:#{user.id}"

  ## Plugs

  @doc "Loads the signed-in user into `:current_scope` (nil when signed out)."
  def fetch_current_scope(conn, _opts) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    case user_from_session(get_session(conn)) do
      %User{} = user -> assign(conn, :current_scope, Scope.for_user(user, via: :browser, ip: ip))
      nil -> assign(conn, :current_scope, nil)
    end
  end

  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_scope] do
      conn
    else
      conn
      |> maybe_store_return_to()
      |> redirect(to: ~p"/")
      |> halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn),
    do: put_session(conn, :return_to, current_path(conn))

  defp maybe_store_return_to(conn), do: conn

  def require_admin(conn, _opts) do
    case conn.assigns[:current_scope] do
      %Scope{user: %User{admin: true}} -> conn
      _ -> conn |> put_status(404) |> text("Not found") |> halt()
    end
  end

  defp user_from_session(%{"user_id" => id, "session_version" => version})
       when is_binary(id) do
    case Accounts.get_user(id) do
      %User{session_version: ^version} = user -> user
      _ -> nil
    end
  end

  defp user_from_session(_), do: nil

  ## LiveView

  @doc """
  `on_mount` hooks:

    * `:mount_current_scope` - assigns `:current_scope` (may be nil);
    * `:require_authenticated` - redirects to sign in when signed out;
    * `:require_admin` - also requires an admin (404 otherwise).
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    end
  end

  def on_mount(:require_admin, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    case socket.assigns.current_scope do
      %Scope{user: %User{admin: true}} -> {:cont, socket}
      _ -> {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/connections")}
    end
  end

  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      case user_from_session(session) do
        %User{} = user ->
          ip =
            Phoenix.LiveView.connected?(socket) && SwitchboardWeb.ClientIP.from_socket(socket)

          Scope.for_user(user, via: :browser, ip: ip || nil)

        nil ->
          nil
      end
    end)
  end
end
