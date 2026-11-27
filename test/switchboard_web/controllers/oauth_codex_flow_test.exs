defmodule SwitchboardWeb.OAuthCodexFlowTest do
  # Dynamic client registration plus code exchange the way Codex 0.172 does it with
  # `--oauth-client-registration dcr` (requests recorded against local dev), and the audit rows
  # every step leaves for the admin view, including the failures that used to leave none.
  # Synchronous: the MCP call runs in anubis' own tasks.
  use SwitchboardWeb.ConnCase, async: false

  import Switchboard.OAuthFixtures
  alias Switchboard.{Audit, OAuth}

  @port 39_263
  @redirect "http://127.0.0.1:#{@port}/callback"

  # What Codex sends to /oauth/register.
  @registration %{
    "client_name" => "Codex",
    "redirect_uris" => [@redirect],
    "grant_types" => ["authorization_code", "refresh_token"],
    "response_types" => ["code"],
    "token_endpoint_auth_method" => "none",
    "application_type" => "native",
    "scope" => "mcp"
  }

  defp register(conn, body \\ @registration) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> post("/oauth/register", Jason.encode!(body))
  end

  defp authorize_query(client_id, challenge) do
    %{
      "response_type" => "code",
      "client_id" => client_id,
      "state" => "N1Gry6rsWODV7SivPhO7og",
      "code_challenge" => challenge,
      "code_challenge_method" => "S256",
      "redirect_uri" => @redirect,
      "scope" => "mcp",
      "resource" => OAuth.resource()
    }
  end

  defp approve(user, client_id, challenge) do
    params = authorize_query(client_id, challenge)
    consent = build_conn() |> log_in_user(user) |> get("/oauth/authorize", params)
    assert html_response(consent, 200) =~ ~s(id="consent-form")

    conn =
      build_conn()
      |> log_in_user(user)
      |> post("/oauth/authorize", Map.put(params, "decision", "approve"))

    location = URI.parse(redirected_to(conn))
    assert location.port == @port
    URI.decode_query(location.query)["code"]
  end

  defp token(conn, form, headers \\ []) do
    conn
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> put_req_header("accept", "application/json")
    |> then(&Enum.reduce(headers, &1, fn {k, v}, c -> put_req_header(c, k, v) end))
    |> post("/oauth/token", URI.encode_query(form))
  end

  defp initialize(access) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> access)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> post(
      "/mcp",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 0,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "codex-mcp-client", "version" => "0.172.0"}
        }
      })
    )
  end

  defp actions(user),
    do: Audit.list(%{user_id: user.id}) |> Enum.map(& &1.action) |> Enum.reverse()

  defp anonymous(action),
    do: Audit.list(%{action: action}) |> Enum.filter(&is_nil(&1.user_id))

  test "register, consent, code exchange (client_id in the body), MCP, refresh", %{conn: conn} do
    user = user_fixture()
    stub_forgejo(user)
    %{"client_id" => client_id} = conn |> register() |> json_response(201)
    {verifier, challenge} = pkce_pair()
    code = approve(user, client_id, challenge)

    form = %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => @redirect,
      "code_verifier" => verifier,
      "client_id" => client_id,
      "resource" => OAuth.resource()
    }

    tokens = build_conn() |> token(form) |> json_response(200)
    assert tokens["token_type"] == "Bearer"
    assert initialize(tokens["access_token"]).status == 200

    refreshed =
      build_conn()
      |> token(%{
        "grant_type" => "refresh_token",
        "refresh_token" => tokens["refresh_token"],
        "client_id" => client_id
      })
      |> json_response(200)

    assert initialize(refreshed["access_token"]).status == 200

    assert ["oauth.approved", "oauth.token_issued", "oauth.token_issued"] = actions(user)
    [refresh, exchange | _] = Audit.list(%{user_id: user.id})
    assert exchange.client_name == "Codex"
    assert exchange.client_id == client_id
    assert exchange.args["grant_type"] == "authorization_code"
    assert refresh.args["grant_type"] == "refresh_token"

    # The registration is audited too (no person yet).
    assert Enum.any?(anonymous("oauth.registered"), &(&1.args["client_id"] == client_id))

    # Never a code, verifier or token in the audit rows.
    stored = Audit.list(%{}) |> Enum.map(&Jason.encode!(Map.take(&1, [:args, :error])))

    for secret <- [code, verifier, tokens["access_token"], tokens["refresh_token"]],
        row <- stored,
        do: refute(row =~ secret)
  end

  test "a client_id sent as HTTP Basic credentials with an empty password works", %{conn: conn} do
    user = user_fixture()
    %{"client_id" => client_id} = conn |> register() |> json_response(201)
    {verifier, challenge} = pkce_pair()
    code = approve(user, client_id, challenge)

    tokens =
      build_conn()
      |> token(
        %{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => @redirect,
          "code_verifier" => verifier
        },
        [{"authorization", "Basic " <> Base.encode64(client_id <> ":")}]
      )
      |> json_response(200)

    assert initialize(tokens["access_token"]).status == 200
  end

  test "failed exchanges are audited with the person, the client and the reason", %{conn: conn} do
    user = user_fixture()
    %{"client_id" => client_id} = conn |> register() |> json_response(201)
    {verifier, challenge} = pkce_pair()

    base = fn code ->
      %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => @redirect,
        "code_verifier" => verifier,
        "client_id" => client_id
      }
    end

    # Wrong verifier.
    code = approve(user, client_id, challenge)
    {other, _} = pkce_pair()
    assert build_conn() |> token(%{base.(code) | "code_verifier" => other}) |> json_response(400)

    # Another loopback port than the one authorized.
    code = approve(user, client_id, challenge)

    assert build_conn()
           |> token(%{base.(code) | "redirect_uri" => "http://127.0.0.1:40000/callback"})
           |> json_response(400)

    # Expired code.
    code = approve(user, client_id, challenge)

    Switchboard.Repo.update_all(Switchboard.OAuth.Code,
      set: [expires_at: DateTime.add(DateTime.utc_now(:second), -5)]
    )

    assert build_conn() |> token(base.(code)) |> json_response(400)

    # A code nobody issued.
    assert build_conn() |> token(base.("not-a-code")) |> json_response(400)

    failures = Audit.list(%{action: "oauth.token_failed"})
    mine = Enum.filter(failures, &(&1.user_id == user.id))

    assert mine |> Enum.map(& &1.args["reason"]) |> Enum.sort() ==
             ["expired_code", "pkce_failed", "redirect_mismatch"]

    assert Enum.all?(mine, &(&1.client_name == "Codex" and &1.outcome == "error"))

    mismatch = Enum.find(mine, &(&1.args["reason"] == "redirect_mismatch"))
    assert mismatch.args["redirect_uri"] == "http://127.0.0.1:40000/callback"
    assert mismatch.args["code_redirect_uri"] == @redirect

    assert Enum.any?(failures, &(is_nil(&1.user_id) and &1.args["reason"] == "unknown_code"))
  end

  test "a reused refresh token and an unknown client are audited", %{conn: conn} do
    user = user_fixture()
    stub_forgejo(user)
    {^user, client, tokens} = token_fixture(user)
    form = %{"grant_type" => "refresh_token", "refresh_token" => tokens["refresh_token"]}
    assert build_conn() |> token(form) |> json_response(200)
    assert build_conn() |> token(form) |> json_response(400)

    assert [%{args: %{"reason" => "refresh_reuse", "client_id" => id}}] =
             Audit.list(%{user_id: user.id, action: "oauth.token_failed"})

    assert id == client.client_id

    assert build_conn()
           |> token(%{
             "grant_type" => "authorization_code",
             "code" => "x",
             "client_id" => "sbc_gone"
           })
           |> json_response(400)

    assert Enum.any?(anonymous("oauth.token_failed"), &(&1.args["reason"] == "unknown_client"))

    # And at /authorize: an unknown client and an unregistered redirect URI.
    {_, challenge} = pkce_pair()
    signed_in = log_in_user(conn, user)

    assert signed_in
           |> get("/oauth/authorize", authorize_query("sbc_gone", challenge))
           |> html_response(400)

    bad = %{
      authorize_query(client.client_id, challenge)
      | "redirect_uri" => "https://elsewhere.example/cb"
    }

    assert build_conn() |> log_in_user(user) |> get("/oauth/authorize", bad) |> html_response(400)

    reasons =
      Audit.list(%{user_id: user.id, action: "oauth.authorize_failed"})
      |> Enum.map(& &1.args["reason"])

    assert Enum.sort(reasons) == ["redirect_uri_not_registered", "unknown_client"]
  end

  test "a refused registration is audited", %{conn: conn} do
    body = %{@registration | "redirect_uris" => ["http://evil.example/cb"]}
    assert conn |> register(body) |> json_response(400)

    assert Enum.any?(
             anonymous("oauth.register_failed"),
             &(&1.args["reason"] == "invalid_redirect_uri" and &1.client_name == "Codex")
           )
  end
end
