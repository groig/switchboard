defmodule Switchboard.ConnectionsTest do
  use Switchboard.DataCase, async: true

  import Switchboard.OAuthFixtures

  alias Switchboard.{Connections, Scope}
  alias Switchboard.Connections.Connection

  setup do
    user = user_fixture(%{email: "ana@example.com"})
    {:ok, user: user, scope: Scope.for_user(user, via: :browser)}
  end

  # One stub for every upstream; it answers by host and path.
  defp stub_upstreams(fun), do: Req.Test.stub(Switchboard.Upstreams, fun)

  defp plane_me(email) do
    stub_upstreams(fn conn ->
      case {conn.host, conn.request_path, Plug.Conn.get_req_header(conn, "x-api-key")} do
        {"plane.test", "/api/v1/users/me/", ["good-key"]} ->
          Req.Test.json(conn, %{
            "email" => email,
            "display_name" => "ana",
            "first_name" => "Ana",
            "last_name" => "García"
          })

        {"plane.test", _, _} ->
          conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "invalid"})
      end
    end)
  end

  test "linking tests the key, records who it belongs to and encrypts it at rest", %{
    scope: scope,
    user: user
  } do
    plane_me("Ana@Example.com")

    assert {:ok, %Connection{status: "ok", identity_matches: true} = conn} =
             Connections.link(scope, "plane", %{"token" => "good-key"})

    assert conn.identity["name"] == "Ana García"
    assert {:ok, %{"token" => "good-key"}} = Connections.credential(user, "plane")

    # The column holds ciphertext, never the key.
    %{rows: [[raw]]} =
      Repo.query!("SELECT secret FROM connections WHERE id = $1", [Ecto.UUID.dump!(conn.id)])

    refute raw =~ "good-key"

    # inspect/1 never prints it.
    refute inspect(Repo.get!(Connection, conn.id)) =~ "good-key"
  end

  test "a key that belongs to someone else is stored but flagged", %{scope: scope} do
    plane_me("bruno@example.com")

    assert {:ok, %{identity_matches: false}} =
             Connections.link(scope, "plane", %{"token" => "good-key"})
  end

  test "a rejected key is not stored", %{scope: scope, user: user} do
    plane_me("ana@example.com")
    assert {:error, :rejected} = Connections.link(scope, "plane", %{"token" => "bad"})
    assert {:error, :not_connected} = Connections.credential(user, "plane")
  end

  @tag :capture_log
  test "when the upstream is down the key is stored untested", %{scope: scope} do
    stub_upstreams(&Req.Test.transport_error(&1, :econnrefused))
    assert {:ok, %{status: "untested"}} = Connections.link(scope, "plane", %{"token" => "k"})
  end

  test "fields are required and Forgejo can't be linked by hand", %{scope: scope} do
    assert {:error, :missing_fields} = Connections.link(scope, "rocketchat", %{"token" => "t"})
    assert {:error, :not_linkable} = Connections.link(scope, "forgejo", %{})
    assert {:error, :not_linkable} = Connections.unlink(scope, "forgejo")
    assert {:error, :unknown_system} = Connections.link(scope, "jira", %{})
  end

  test "each adapter reads its identity endpoint", %{scope: scope} do
    stub_upstreams(fn conn ->
      case {conn.host, conn.request_path} do
        {"chat.test", "/api/v1/me"} ->
          ["uid-1"] = Plug.Conn.get_req_header(conn, "x-user-id")

          Req.Test.json(conn, %{
            "username" => "ana",
            "name" => "Ana",
            "emails" => [%{"address" => "ana@example.com"}]
          })

        {"outline.test", "/api/auth.info"} ->
          ["Bearer ol-key"] = Plug.Conn.get_req_header(conn, "authorization")

          Req.Test.json(conn, %{
            "data" => %{"user" => %{"name" => "Ana", "email" => "ana@example.com"}}
          })

        {"argus.test", "/api/v1/me"} ->
          conn
          |> Plug.Conn.put_resp_content_type("text/markdown")
          |> Plug.Conn.send_resp(
            200,
            "# You\n\nEmail: Ana@example.com\nName: Ana\nRole: member\nTeams: billing, web\n"
          )
      end
    end)

    assert {:ok, %{identity_matches: true}} =
             Connections.link(scope, "rocketchat", %{"user_id" => "uid-1", "token" => "rc"})

    assert {:ok, %{identity_matches: true}} =
             Connections.link(scope, "outline", %{"token" => "ol-key"})

    assert {:ok,
            %{
              identity_matches: true,
              identity: %{"role" => "member", "teams" => ["billing", "web"]}
            }} =
             Connections.link(scope, "argus", %{"token" => "argus_abc"})

    assert {:error, :invalid_format} = Connections.link(scope, "argus", %{"token" => "nope"})
  end

  test "unlink removes the key and is audited", %{scope: scope, user: user} do
    plane_me("ana@example.com")
    {:ok, _} = Connections.link(scope, "plane", %{"token" => "good-key"})
    :ok = Connections.unlink(scope, "plane")
    assert {:error, :not_connected} = Connections.credential(user, "plane")
    assert [%{action: "connection.unlinked"} | _] = Switchboard.Audit.list_mine(scope)
  end

  describe "forgejo_token/1" do
    defp expire_forgejo(user) do
      Repo.update_all(
        from(c in Connection, where: c.user_id == ^user.id and c.system == "forgejo"),
        set: [expires_at: DateTime.add(DateTime.utc_now(:second), 30)]
      )
    end

    test "returns the stored token while it is fresh", %{user: user} do
      assert {:ok, "forgejo-token-" <> _} = Connections.forgejo_token(user)
    end

    test "refreshes it (and stores the rotated refresh token) when it is about to expire", %{
      user: user
    } do
      expire_forgejo(user)

      Req.Test.stub(Switchboard.Forgejo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert params["grant_type"] == "refresh_token"
        assert params["refresh_token"] =~ "forgejo-refresh-"

        Req.Test.json(conn, %{
          "access_token" => "new-access",
          "refresh_token" => "new-refresh",
          "expires_in" => 3600
        })
      end)

      assert {:ok, "new-access"} = Connections.forgejo_token(user)
      assert %{secret: %{"refresh_token" => "new-refresh"}} = Connections.get(user, "forgejo")
      # Fresh again: no second refresh.
      assert {:ok, "new-access"} = Connections.forgejo_token(user)
    end

    test "a rejected refresh marks the connection and reports :unauthorized", %{user: user} do
      expire_forgejo(user)

      Req.Test.stub(Switchboard.Forgejo, fn conn ->
        conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})
      end)

      assert {:error, :unauthorized} = Connections.forgejo_token(user)
      assert %{status: "rejected"} = Connections.get(user, "forgejo")
    end
  end

  test "reencrypt_all/0 rewrites every secret readable", %{scope: scope, user: user} do
    plane_me("ana@example.com")
    {:ok, _} = Connections.link(scope, "plane", %{"token" => "good-key"})
    :ok = Connections.reencrypt_all()
    assert {:ok, %{"token" => "good-key"}} = Connections.credential(user, "plane")
  end
end
