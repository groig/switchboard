defmodule SwitchboardWeb.Plugs.MCPAuth do
  @moduledoc """
  Authenticates `/mcp` requests with a bearer token and assigns `:current_scope`: an OAuth access
  token (`sbat_...`) or a personal gateway token (`sb_...`).

  Without a valid token it answers `401` with `WWW-Authenticate: Bearer resource_metadata=...`
  (RFC 9728 §5.1), which is how MCP clients discover the authorization server.
  """
  @behaviour Plug
  import Plug.Conn

  alias Switchboard.{OAuth, PersonalTokens, Scope}

  require Logger

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, scope} <- authenticate(String.trim(token)) do
      scope = %{scope | ip: conn.remote_ip |> :inet.ntoa() |> to_string()}
      Logger.metadata(user: scope.user.username, mcp_client: scope.client_name)
      assign(conn, :current_scope, scope)
    else
      _ -> unauthorized(conn)
    end
  end

  # OAuth access tokens (sbat_) or personal gateway tokens (sb_).
  defp authenticate("sbat_" <> _ = token) do
    with {:ok, user, grant} <- OAuth.verify_access_token(token) do
      {:ok,
       Scope.for_user(user,
         client_id: grant.client_id,
         client_name: grant.client_name,
         grant_id: grant.id
       )}
    end
  end

  defp authenticate("sb_" <> _ = token) do
    with {:ok, user, personal} <- PersonalTokens.verify(token) do
      {:ok, Scope.for_user(user, client_name: personal.name, via: :personal_token)}
    end
  end

  defp authenticate(_), do: {:error, :invalid_token}

  @doc "The value of the `WWW-Authenticate` header for an unauthenticated MCP request."
  def www_authenticate do
    ~s(Bearer resource_metadata="#{OAuth.issuer()}/.well-known/oauth-protected-resource/mcp", scope="mcp")
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_header("www-authenticate", www_authenticate())
    |> put_resp_content_type("application/json")
    |> send_resp(
      401,
      Jason.encode!(%{
        error: "invalid_token",
        error_description: "Sign in to Switchboard (OAuth) to use this server."
      })
    )
    |> halt()
  end
end
