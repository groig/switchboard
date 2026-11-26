defmodule SwitchboardWeb.Plugs.ContentSecurityPolicy do
  @moduledoc """
  Sets a strict Content-Security-Policy with a per-request nonce.

  Scripts only load from our origin, plus the one inline script in the root layout (theme before
  first paint), which carries the nonce. Inline `style` attributes are allowed because
  LiveView's JS commands set them. Nothing is loaded from third parties.

  `form-action` is `'self'`, except on the OAuth consent page, which adds the client's redirect
  origin (`allow_form_action/2`): browsers check the redirect that follows a form post too.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.encode64()

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", policy(nonce, []))
  end

  @doc "Re-issues the policy with `uri`'s origin added to `form-action`."
  def allow_form_action(conn, uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host} = parsed
      when scheme in ["http", "https"] and is_binary(host) ->
        origin = "#{scheme}://#{host_for_csp(host)}#{port_for_csp(parsed)}"
        put_resp_header(conn, "content-security-policy", policy(conn.assigns.csp_nonce, [origin]))

      _ ->
        conn
    end
  end

  defp host_for_csp(host), do: if(String.contains?(host, ":"), do: "[#{host}]", else: host)

  # Loopback clients pick a random port at run time, and the redirect URI is the one they sent.
  defp port_for_csp(%URI{port: port, scheme: scheme})
       when port in [80, 443] and scheme in ["http", "https"],
       do: ""

  defp port_for_csp(%URI{port: port}) when is_integer(port), do: ":#{port}"
  defp port_for_csp(_), do: ""

  defp policy(nonce, form_origins) do
    Enum.join(
      [
        "default-src 'self'",
        "script-src 'self' 'nonce-#{nonce}'",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data:",
        "font-src 'self'",
        "connect-src 'self' #{websocket_origins()}",
        "object-src 'none'",
        "frame-src #{frame_src()}",
        "frame-ancestors 'none'",
        "base-uri 'self'",
        "form-action #{Enum.join(["'self'" | form_origins], " ")}",
        "manifest-src 'self'"
      ],
      "; "
    )
  end

  # Dev only: the live-reload iframe is same-origin.
  defp frame_src, do: Application.get_env(:switchboard, :csp_frame_src, "'none'")

  # Browsers disagree on whether 'self' covers ws(s): of the same host.
  defp websocket_origins do
    url = SwitchboardWeb.Endpoint.url()
    String.replace(url, ~r/^http/, "ws")
  end
end
