defmodule SwitchboardWeb.OAuthControllerTest do
  use SwitchboardWeb.ConnCase, async: true

  import Switchboard.OAuthFixtures
  alias Switchboard.OAuth

  test "authorization server metadata advertises PKCE S256, CIMD and iss", %{conn: conn} do
    body = conn |> get("/.well-known/oauth-authorization-server") |> json_response(200)
    assert body["issuer"] == OAuth.issuer()
    assert body["code_challenge_methods_supported"] == ["S256"]
    assert body["client_id_metadata_document_supported"]
    assert body["authorization_response_iss_parameter_supported"]
  end

  test "protected resource metadata is served at the path-inserted and root URIs", %{conn: conn} do
    for path <- [
          "/.well-known/oauth-protected-resource/mcp",
          "/.well-known/oauth-protected-resource"
        ] do
      body = conn |> get(path) |> json_response(200)
      assert body["resource"] == OAuth.resource()
      assert body["authorization_servers"] == [OAuth.issuer()]
    end
  end

  test "an anonymous authorize request goes to the Forgejo login", %{conn: conn} do
    client = dcr_client_fixture()
    {_, challenge} = pkce_pair()
    conn = get(conn, "/oauth/authorize", authorize_params(client, challenge))
    assert redirected_to(conn) == "/auth/forgejo"
  end

  test "a signed-in user sees consent; approving redirects with code, state and iss", %{
    conn: conn
  } do
    user = user_fixture()
    client = dcr_client_fixture()
    {_, challenge} = pkce_pair()
    params = authorize_params(client, challenge)
    conn = log_in_user(conn, user)

    consent = get(conn, "/oauth/authorize", params)
    html = html_response(consent, 200)
    assert html =~ ~s(id="consent-form")
    assert html =~ "127.0.0.1"
    # A self-registered (DCR) client is flagged as unverified.
    assert html =~ ~s(id="consent-unverified")

    # The form's redirect to the loopback client must be allowed by the CSP.
    [csp] = get_resp_header(consent, "content-security-policy")
    assert csp =~ "form-action 'self' http://127.0.0.1:53111"

    conn =
      conn
      |> recycle()
      |> log_in_user(user)
      |> post("/oauth/authorize", Map.put(params, "decision", "approve"))

    location = URI.parse(redirected_to(conn))
    query = URI.decode_query(location.query)
    assert location.port == 53111
    assert query["state"] == "xyz"
    assert query["iss"] == OAuth.issuer()
    assert is_binary(query["code"])
    assert [%{action: "oauth.approved"}] = Switchboard.Audit.list(%{user_id: user.id})
  end

  test "other pages keep form-action to 'self'", %{conn: conn} do
    [csp] = conn |> get("/") |> get_resp_header("content-security-policy")
    assert csp =~ "form-action 'self';"
    assert csp =~ "frame-ancestors 'none'"
  end

  test "an unregistered redirect URI is shown as an error, never redirected to", %{conn: conn} do
    user = user_fixture()
    client = dcr_client_fixture()
    {_, challenge} = pkce_pair()

    conn =
      conn
      |> log_in_user(user)
      |> get(
        "/oauth/authorize",
        authorize_params(client, challenge, %{"redirect_uri" => "https://evil.example/cb"})
      )

    assert html_response(conn, 400) =~ "redirect URI"
  end

  test "the token endpoint answers errors as JSON with no-store", %{conn: conn} do
    conn = post(conn, "/oauth/token", %{"grant_type" => "authorization_code", "code" => "nope"})
    assert %{"error" => "invalid_grant"} = json_response(conn, 400)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end
end
