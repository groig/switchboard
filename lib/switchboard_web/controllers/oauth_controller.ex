defmodule SwitchboardWeb.OAuthController do
  @moduledoc """
  Switchboard's OAuth 2.1 authorization server endpoints for MCP clients: metadata (RFC 8414,
  RFC 9728), registration (RFC 7591), authorize + consent, token and revocation (RFC 7009).
  """
  use SwitchboardWeb, :controller

  alias Switchboard.{Audit, OAuth, Scope}
  alias SwitchboardWeb.Plugs.ContentSecurityPolicy

  ## Metadata

  def authorization_server_metadata(conn, _params) do
    issuer = OAuth.issuer()

    json(conn, %{
      issuer: issuer,
      authorization_endpoint: issuer <> ~p"/oauth/authorize",
      token_endpoint: issuer <> ~p"/oauth/token",
      registration_endpoint: issuer <> ~p"/oauth/register",
      revocation_endpoint: issuer <> ~p"/oauth/revoke",
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["none"],
      revocation_endpoint_auth_methods_supported: ["none"],
      scopes_supported: ["mcp"],
      client_id_metadata_document_supported: true,
      authorization_response_iss_parameter_supported: true
    })
  end

  def protected_resource_metadata(conn, _params) do
    json(conn, %{
      resource: OAuth.resource(),
      authorization_servers: [OAuth.issuer()],
      scopes_supported: ["mcp"],
      bearer_methods_supported: ["header"],
      resource_name: "Switchboard"
    })
  end

  ## Dynamic Client Registration

  def register(conn, params) do
    case OAuth.register_client(params, audit_scope(conn)) do
      {:ok, client} ->
        conn
        |> put_status(201)
        |> no_store()
        |> json(%{
          client_id: client.client_id,
          client_id_issued_at: DateTime.to_unix(client.inserted_at),
          client_name: client.client_name,
          redirect_uris: client.redirect_uris,
          grant_types: ["authorization_code", "refresh_token"],
          response_types: ["code"],
          token_endpoint_auth_method: "none"
        })

      {:error, error, description} ->
        conn |> put_status(400) |> json(%{error: error, error_description: description})
    end
  end

  ## Authorization

  def authorize(conn, params) do
    case OAuth.validate_authorize_request(params, audit_scope(conn)) do
      {:ok, request} ->
        case conn.assigns.current_scope do
          nil ->
            conn
            |> put_session(:return_to, current_path(conn))
            |> redirect(to: ~p"/auth/forgejo")

          scope ->
            conn
            # The consent form's response redirects to the client; browsers apply form-action
            # to that redirect, so the client's origin must be allowed for this page.
            |> ContentSecurityPolicy.allow_form_action(request.redirect_uri)
            |> render(:consent,
              request: request,
              params:
                Map.take(
                  params,
                  ~w(client_id redirect_uri response_type code_challenge code_challenge_method resource scope state)
                ),
              redirect_host: URI.parse(request.redirect_uri).host,
              client_name: request.client.client_name || gettext("an MCP client"),
              user: scope.user,
              page_title: gettext("Authorize a client")
            )
        end

      {:error, :no_redirect, message} ->
        conn
        |> put_status(400)
        |> render(:error, message: message, page_title: gettext("Authorization error"))

      {:error, :redirect, redirect_uri, error, description, state} ->
        redirect_back(conn, redirect_uri, %{
          "error" => error,
          "error_description" => description,
          "state" => state
        })
    end
  end

  def decide(conn, %{"decision" => decision} = params) do
    scope = conn.assigns.current_scope

    case {scope, OAuth.validate_authorize_request(params, audit_scope(conn))} do
      {nil, _} ->
        conn
        |> put_status(401)
        |> render(:error,
          message: gettext("Your session expired. Start again from your client."),
          page_title: gettext("Authorization error")
        )

      {_, {:ok, request}} when decision == "approve" ->
        code = OAuth.create_code(scope.user, request)

        Audit.log_web(
          %{scope | client_id: request.client_id, client_name: request.client.client_name},
          "oauth.approved",
          %{
            client_id: request.client_id,
            client_kind: request.client.kind,
            redirect_uri: request.redirect_uri
          }
        )

        redirect_back(conn, request.redirect_uri, %{"code" => code, "state" => request.state})

      {_, {:ok, request}} ->
        Audit.log_web(scope, "oauth.denied", %{client_id: request.client_id})

        redirect_back(conn, request.redirect_uri, %{
          "error" => "access_denied",
          "state" => request.state
        })

      {_, {:error, :no_redirect, message}} ->
        conn
        |> put_status(400)
        |> render(:error, message: message, page_title: gettext("Authorization error"))

      {_, {:error, :redirect, redirect_uri, error, description, state}} ->
        redirect_back(conn, redirect_uri, %{
          "error" => error,
          "error_description" => description,
          "state" => state
        })
    end
  end

  # RFC 9207: every authorization response names the issuer.
  defp redirect_back(conn, redirect_uri, params) do
    params = params |> Map.put("iss", OAuth.issuer()) |> Map.reject(fn {_, v} -> is_nil(v) end)
    uri = URI.parse(redirect_uri)
    query = URI.decode_query(uri.query || "") |> Map.merge(params) |> URI.encode_query()
    redirect(conn, external: URI.to_string(%{uri | query: query}))
  end

  ## Token

  def token(conn, params) do
    case OAuth.token(client_basic_auth(conn, params), audit_scope(conn)) do
      {:ok, response} ->
        conn |> no_store() |> json(response)

      {:error, error, description} ->
        conn
        |> no_store()
        |> put_status(400)
        |> json(%{error: error, error_description: description})
    end
  end

  def revoke(conn, params) do
    OAuth.revoke_token(params["token"])
    conn |> no_store() |> send_resp(200, "")
  end

  # Who an OAuth request comes from, for its audit row: the signed-in person on the browser
  # endpoints, nobody yet on the client endpoints (OAuth fills in the code's or token's owner).
  defp audit_scope(conn) do
    user =
      case conn.assigns[:current_scope] do
        %Scope{user: user} -> user
        _ -> nil
      end

    %Scope{user: user, ip: conn.remote_ip |> :inet.ntoa() |> to_string(), via: :oauth}
  end

  # A public client may send its client_id as HTTP Basic credentials with an empty password
  # (RFC 6749 §2.3.1) instead of in the body; take it from there when the body has none.
  defp client_basic_auth(conn, params) do
    with nil <- params["client_id"],
         ["Basic " <> encoded] <- get_req_header(conn, "authorization"),
         {:ok, decoded} <- Base.decode64(String.trim(encoded)),
         [id, ""] <- String.split(decoded, ":", parts: 2) do
      Map.put(params, "client_id", URI.decode_www_form(id))
    else
      _ -> params
    end
  end

  defp no_store(conn) do
    conn |> put_resp_header("cache-control", "no-store") |> put_resp_header("pragma", "no-cache")
  end
end
