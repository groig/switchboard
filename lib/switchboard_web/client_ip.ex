defmodule SwitchboardWeb.ClientIP do
  @moduledoc """
  The real client IP behind a reverse proxy.

  `X-Forwarded-For` is honoured only when the direct peer is a trusted proxy
  (`TRUSTED_PROXIES`, a comma-separated list of CIDRs; loopback by default).
  The header is then read right to left, skipping trusted proxies, so a
  client can't spoof its address by sending its own header.

  Used as a plug (sets `conn.remote_ip`) and for LiveView sockets
  (`from_socket/1`, from connect info).
  """
  @behaviour Plug
  import Bitwise

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    forwarded = Plug.Conn.get_req_header(conn, "x-forwarded-for")
    from_proxy? = trusted?(conn.remote_ip, trusted())

    conn = %{conn | remote_ip: resolve(conn.remote_ip, forwarded)}

    # Caddy terminates TLS: trust its X-Forwarded-Proto so cookies are Secure
    # and generated URLs use https.
    case from_proxy? && Plug.Conn.get_req_header(conn, "x-forwarded-proto") do
      ["https" | _] -> %{conn | scheme: :https, port: 443}
      _ -> conn
    end
  end

  @doc "The client IP of a LiveView socket, as a string (or nil)."
  def from_socket(socket) do
    with %{address: peer} <- Phoenix.LiveView.get_connect_info(socket, :peer_data) do
      headers = Phoenix.LiveView.get_connect_info(socket, :x_headers) || []
      forwarded = for {"x-forwarded-for", value} <- headers, do: value
      peer |> resolve(forwarded) |> to_string_ip()
    else
      _ -> nil
    end
  end

  def to_string_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  def to_string_ip(_), do: nil

  @doc false
  def resolve(peer, forwarded_headers) do
    trusted = trusted()

    if trusted?(peer, trusted) do
      forwarded_headers
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reverse()
      |> Enum.map(&parse/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.find(peer, &(not trusted?(&1, trusted)))
    else
      peer
    end
  end

  defp parse(string) do
    case :inet.parse_address(String.to_charlist(string)) do
      {:ok, ip} -> ip
      _ -> nil
    end
  end

  @doc "Whether an IP is inside a CIDR string."
  def in_cidr?(ip, cidr) do
    case parse_cidr(cidr) do
      nil -> false
      range -> in_range?(ip, range)
    end
  end

  def allowed_admin_ip?(ip) do
    case Application.get_env(:switchboard, :admin_networks) do
      nil -> true
      ranges -> Enum.any?(ranges, fn range -> in_range?(ip, parse_cidr(range)) end)
    end
  end

  defp trusted do
    Application.get_env(:switchboard, :trusted_proxies, ["127.0.0.0/8", "::1/128"])
    |> Enum.map(&parse_cidr/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc false
  def parse_cidr(cidr) do
    {addr, bits} =
      case String.split(String.trim(cidr), "/") do
        [addr, bits] -> {addr, String.to_integer(bits)}
        [addr] -> {addr, nil}
      end

    case parse(addr) do
      nil -> nil
      ip -> {ip, bits || tuple_size(ip) * if(tuple_size(ip) == 4, do: 8, else: 16)}
    end
  rescue
    ArgumentError -> nil
  end

  defp trusted?(ip, ranges), do: Enum.any?(ranges, &in_range?(ip, &1))

  defp in_range?(ip, {net, bits}) when tuple_size(ip) == tuple_size(net) do
    width = if tuple_size(ip) == 4, do: 32, else: 128
    mask = (1 <<< width) - (1 <<< (width - bits))
    (to_int(ip) &&& mask) == (to_int(net) &&& mask)
  end

  defp in_range?(_ip, _range), do: false

  defp to_int({a, b, c, d}), do: (a <<< 24) + (b <<< 16) + (c <<< 8) + d

  defp to_int(ip) when tuple_size(ip) == 8,
    do: ip |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> (acc <<< 16) + part end)
end
