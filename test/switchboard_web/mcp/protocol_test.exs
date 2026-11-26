defmodule SwitchboardWeb.MCP.ProtocolTest do
  use SwitchboardWeb.ConnCase, async: false

  import Switchboard.OAuthFixtures
  import Ecto.Query
  alias Switchboard.OAuth

  defp mcp(conn, body, headers \\ []) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> then(fn conn ->
      Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    end)
    |> post("/mcp", Jason.encode!(body))
  end

  defp json_rpc(conn) do
    body = conn.resp_body

    body =
      if String.starts_with?(
           get_resp_header(conn, "content-type") |> List.first() || "",
           "text/event-stream"
         ),
         do:
           body
           |> String.split("\n")
           |> Enum.find_value(
             &(String.starts_with?(&1, "data: ") && String.trim_leading(&1, "data: "))
           ),
         else: body

    Jason.decode!(body)
  end

  @init %{
    "jsonrpc" => "2.0",
    "id" => 1,
    "method" => "initialize",
    "params" => %{
      "protocolVersion" => "2025-06-18",
      "capabilities" => %{},
      "clientInfo" => %{"name" => "test", "version" => "0"}
    }
  }

  test "requests without a token get 401 with the resource metadata pointer", %{conn: conn} do
    conn = mcp(conn, @init)
    assert conn.status == 401
    [challenge] = get_resp_header(conn, "www-authenticate")

    assert challenge =~
             ~s(resource_metadata="#{OAuth.issuer()}/.well-known/oauth-protected-resource/mcp")
  end

  test "an invalid or revoked token gets 401", %{conn: conn} do
    assert mcp(put_req_header(conn, "authorization", "Bearer sbat_nope"), @init).status == 401

    {_user, _client, %{"access_token" => access}} = token_fixture()
    {:ok, _user, grant} = OAuth.verify_access_token(access)
    OAuth.revoke_grant(grant, "test")

    assert mcp(put_req_header(build_conn(), "authorization", "Bearer " <> access), @init).status ==
             401
  end

  test "initialize, tools/list and tools/call whoami (2025-06-18 session)", %{conn: conn} do
    {user, _client, %{"access_token" => access}} = token_fixture()
    auth = [{"authorization", "Bearer " <> access}]

    conn = mcp(conn, @init, auth)

    assert %{"result" => %{"protocolVersion" => "2025-06-18", "instructions" => instructions}} =
             json_rpc(conn)

    assert instructions =~ "untrusted"
    [session] = get_resp_header(conn, "mcp-session-id")

    session_headers =
      auth ++ [{"mcp-session-id", session}, {"mcp-protocol-version", "2025-06-18"}]

    assert mcp(
             build_conn(),
             %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
             session_headers
           ).status == 202

    list =
      mcp(
        build_conn(),
        %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list", "params" => %{}},
        session_headers
      )
      |> json_rpc()

    whoami = Enum.find(list["result"]["tools"], &(&1["name"] == "whoami"))
    assert whoami["annotations"]["readOnlyHint"] == true

    call =
      mcp(
        build_conn(),
        %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "tools/call",
          "params" => %{"name" => "whoami", "arguments" => %{}}
        },
        session_headers
      )
      |> json_rpc()

    assert %{
             "result" => %{"isError" => false, "content" => [%{"type" => "text", "text" => text}]}
           } = call

    assert text =~ user.username
  end

  test "server/discover (2026-07-28, stateless) returns the instructions", %{conn: conn} do
    {_user, _client, %{"access_token" => access}} = token_fixture()

    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "server/discover",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    conn =
      mcp(conn, body, [
        {"authorization", "Bearer " <> access},
        {"mcp-protocol-version", "2026-07-28"},
        {"mcp-method", "server/discover"}
      ])

    assert %{"result" => %{"instructions" => _, "supportedVersions" => versions}} = json_rpc(conn)
    assert "2026-07-28" in versions
  end

  describe "personal tokens" do
    test "a valid sb_ token authenticates; revoked and expired ones don't", %{conn: conn} do
      user = user_fixture()
      scope = Switchboard.Scope.for_user(user, via: :browser)
      {:ok, token, record} = Switchboard.PersonalTokens.create(scope, "Zed", 30)

      conn = mcp(put_req_header(conn, "authorization", "Bearer " <> token), @init)
      assert conn.status == 200

      :ok = Switchboard.PersonalTokens.revoke(scope, record.id)

      assert mcp(put_req_header(build_conn(), "authorization", "Bearer " <> token), @init).status ==
               401

      {:ok, expired, rec2} = Switchboard.PersonalTokens.create(scope, "Old", 7)

      Switchboard.Repo.update_all(
        from(t in Switchboard.PersonalTokens.PersonalToken, where: t.id == ^rec2.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(:second), -1)]
      )

      assert mcp(put_req_header(build_conn(), "authorization", "Bearer " <> expired), @init).status ==
               401
    end
  end

  test "tool calls through the Plug are audited with the client name", %{conn: conn} do
    {user, _client, %{"access_token" => access}} = token_fixture()
    conn = put_req_header(conn, "authorization", "Bearer " <> access)

    call = %{
      "jsonrpc" => "2.0",
      "id" => 7,
      "method" => "tools/call",
      "params" => %{
        "name" => "whoami",
        "arguments" => %{},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    resp =
      mcp(conn, call, [
        {"mcp-protocol-version", "2026-07-28"},
        {"mcp-method", "tools/call"},
        {"mcp-name", "whoami"}
      ])

    assert %{"result" => %{"isError" => false}} = json_rpc(resp)

    assert [%{action: "whoami", kind: "mcp", outcome: "ok", client_name: "Test client"}] =
             Switchboard.Audit.list(%{user_id: user.id, kind: "mcp"})
  end
end
