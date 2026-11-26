defmodule SwitchboardWeb.AdminNetwork do
  @moduledoc """
  Defence in depth for `/admin` and `/dev`: the reverse proxy should already limit them to a
  private network (a VPN); when `ADMIN_NETWORKS` (CIDRs) is set, the app refuses other client
  addresses too (404).
  """
  @behaviour Plug
  alias SwitchboardWeb.ClientIP

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _) do
    if protected?(conn.path_info) and not ClientIP.allowed_admin_ip?(conn.remote_ip) do
      conn |> Plug.Conn.send_resp(404, "Not found") |> Plug.Conn.halt()
    else
      conn
    end
  end

  defp protected?([path | _]) when path in ["admin", "dev"], do: true
  defp protected?(_), do: false

  def on_mount(:default, _, _, socket) do
    if Phoenix.LiveView.connected?(socket) && Application.get_env(:switchboard, :admin_networks) do
      with ip when is_binary(ip) <- ClientIP.from_socket(socket),
           {:ok, addr} <- :inet.parse_address(String.to_charlist(ip)),
           true <- ClientIP.allowed_admin_ip?(addr) do
        {:cont, socket}
      else
        _ -> {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
      end
    else
      {:cont, socket}
    end
  end
end
