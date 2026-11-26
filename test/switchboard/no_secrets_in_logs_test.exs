defmodule Switchboard.NoSecretsInLogsTest do
  @moduledoc """
  Runs every flow that handles a secret with logging at :debug, then checks that no secret
  appears in the log or in any audit row:

    * linking and re-linking every connection type (context and LiveView form);
    * Forgejo sign-in (code exchange, tokens) and token refresh;
    * OAuth for MCP clients: registration, consent, code exchange, refresh, revocation, a tool
      call with the bearer;
    * personal tokens: creation (LiveView) and use;
    * Rocket.Chat writes as the person and as the bot user;
    * Rocket.Chat reads (`chat_inbox`, `chat_read`: message text is private too), watch
      notices, and the Forgejo webhook (its secret and signature).
  """
  use SwitchboardWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Switchboard.{Connections, OAuth, PersonalTokens, Repo, Scope, Tools}
  alias Switchboard.Audit.Event

  import Ecto.Query

  setup do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)
  end

  # Every secret below contains this marker, so one search finds them all.
  @m "SEKRET"

  defp secret(name), do: "#{name}-#{@m}-#{System.unique_integer([:positive])}"

  defp assert_clean(log) do
    refute log =~ @m, "a secret reached the log:\n" <> excerpt(log)

    {events, _log} = with_log(fn -> Repo.all(Event) end)
    audit = events |> Enum.map(&Map.take(&1, [:args, :error])) |> inspect(limit: :infinity)

    refute audit =~ @m, "a secret reached the audit log"
  end

  defp excerpt(log) do
    log |> String.split("\n") |> Enum.filter(&(&1 =~ @m)) |> Enum.take(5) |> Enum.join("\n")
  end

  # Upstream identity endpoints answer for any key; writes succeed.
  defp stub_everything(user) do
    Req.Test.stub(Switchboard.Upstreams, fn conn ->
      case {conn.host, conn.request_path} do
        {"argus.test", "/api/v1/me"} ->
          conn
          |> Plug.Conn.put_resp_content_type("text/markdown")
          |> Plug.Conn.send_resp(
            200,
            "Email: #{user.email}\nName: x\nRole: member\nTeams: none\n"
          )

        {"chat.test", "/api/v1/me"} ->
          Req.Test.json(conn, %{
            "username" => user.username,
            "emails" => [%{"address" => user.email}]
          })

        {"chat.test", "/api/v1/users.info"} ->
          Req.Test.json(conn, %{
            "user" => %{"username" => user.username, "name" => user.name, "active" => true}
          })

        {"chat.test", "/api/v1/rooms.info"} ->
          Req.Test.json(conn, %{"room" => %{"_id" => "r1", "t" => "c"}})

        {"chat.test", "/api/v1/subscriptions.getOne"} ->
          Req.Test.json(conn, %{"subscription" => %{"rid" => "r1"}})

        {"chat.test", "/api/v1/im.create"} ->
          Req.Test.json(conn, %{"room" => %{"_id" => "dm1"}})

        {"chat.test", "/api/v1/chat.postMessage"} ->
          Req.Test.json(conn, %{"message" => %{"_id" => "m1"}})

        _ ->
          Req.Test.json(conn, %{
            "email" => user.email,
            "display_name" => "x",
            "data" => %{"user" => %{"email" => user.email}}
          })
      end
    end)
  end

  test "connections of every type, linked and re-linked, through the context and the LiveView form",
       %{conn: conn} do
    {user, _} = with_log(fn -> user_fixture() end)
    scope = Scope.for_user(user)
    stub_everything(user)

    log =
      capture_log([level: :debug], fn ->
        for _round <- 1..2 do
          {:ok, _} = Connections.link(scope, "plane", %{"token" => secret("plane")})
          {:ok, _} = Connections.link(scope, "argus", %{"token" => "argus_" <> secret("argus")})
          {:ok, _} = Connections.link(scope, "outline", %{"token" => secret("outline")})

          {:ok, _} =
            Connections.link(scope, "rocketchat", %{
              "token" => secret("rc"),
              "user_id" => secret("rcuid")
            })
        end

        for system <- ~w(plane argus outline rocketchat),
            do: {:ok, _} = Connections.test(scope, system)

        # The LiveView form (its debug log prints event parameters).
        {:ok, view, _} = live(log_in_user(conn, user), ~p"/connections")
        Req.Test.allow(Switchboard.Upstreams, self(), view.pid)
        view |> element("#replace-plane") |> render_click()
        view |> form("#link-form", credential: %{token: secret("plane-form")}) |> render_submit()
        view |> element("#replace-rocketchat") |> render_click()

        view
        |> form("#link-form",
          credential: %{token: secret("rc-form"), user_id: secret("rc-form-uid")}
        )
        |> render_submit()

        Logger.flush()
      end)

    assert log =~ "QUERY OK"
    assert_clean(log)
  end

  test "Forgejo sign-in and token refresh", %{conn: conn} do
    access = secret("fg-access")
    refresh = secret("fg-refresh")
    new_access = secret("fg-access2")

    Req.Test.stub(Switchboard.Forgejo, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)

      case {conn.request_path, params["grant_type"]} do
        {"/login/oauth/access_token", "refresh_token"} ->
          Req.Test.json(conn, %{
            "access_token" => new_access,
            "refresh_token" => secret("fg-refresh2"),
            "expires_in" => 3600
          })

        {"/login/oauth/access_token", _} ->
          Req.Test.json(conn, %{
            "access_token" => access,
            "refresh_token" => refresh,
            "expires_in" => 3600
          })

        {"/api/v1/user", _} ->
          Req.Test.json(conn, %{
            "id" => 77_001,
            "login" => "logcheck",
            "email" => "logcheck@example.com",
            "active" => true
          })

        {"/api/v1/user/orgs", _} ->
          Req.Test.json(conn, [%{"username" => "Acme"}])
      end
    end)

    log =
      capture_log([level: :debug], fn ->
        conn = get(conn, ~p"/auth/forgejo")
        %{"state" => state} = URI.decode_query(URI.parse(redirected_to(conn)).query)

        conn =
          get(recycle(conn), ~p"/auth/forgejo/callback?code=#{secret("fg-code")}&state=#{state}")

        assert redirected_to(conn) == ~p"/connections"

        user = Repo.get_by!(Switchboard.Accounts.User, username: "logcheck")

        Repo.update_all(
          from(c in Connections.Connection, where: c.user_id == ^user.id),
          set: [expires_at: DateTime.utc_now(:second)]
        )

        {:ok, ^new_access} = Connections.forgejo_token(user)
        Logger.flush()
      end)

    assert_clean(log)
  end

  test "OAuth for MCP clients: registration, consent, exchange, refresh, revocation and a tool call",
       %{conn: conn} do
    {user, _} = with_log(fn -> user_fixture() end)
    stub_forgejo(user)

    log =
      capture_log([level: :debug], fn ->
        reg =
          conn
          |> put_req_header("content-type", "application/json")
          |> post(
            ~p"/oauth/register",
            Jason.encode!(%{
              "client_name" => "logcheck",
              "redirect_uris" => ["http://127.0.0.1/callback"]
            })
          )
          |> json_response(201)

        verifier = secret("verifier") |> String.pad_trailing(50, "x")
        challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

        params = %{
          "response_type" => "code",
          "client_id" => reg["client_id"],
          "redirect_uri" => "http://127.0.0.1:5000/callback",
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "resource" => OAuth.resource(),
          "state" => "s"
        }

        approved =
          build_conn()
          |> log_in_user(user)
          |> post(~p"/oauth/authorize", Map.put(params, "decision", "approve"))

        %{"code" => code} = URI.decode_query(URI.parse(redirected_to(approved)).query)

        tokens =
          build_conn()
          |> post(~p"/oauth/token", %{
            "grant_type" => "authorization_code",
            "code" => code,
            "client_id" => reg["client_id"],
            "redirect_uri" => params["redirect_uri"],
            "code_verifier" => verifier,
            "resource" => OAuth.resource()
          })
          |> json_response(200)

        refreshed =
          build_conn()
          |> post(~p"/oauth/token", %{
            "grant_type" => "refresh_token",
            "refresh_token" => tokens["refresh_token"],
            "client_id" => reg["client_id"]
          })
          |> json_response(200)

        call =
          build_conn()
          |> put_req_header("authorization", "Bearer " <> refreshed["access_token"])
          |> put_req_header("content-type", "application/json")
          |> put_req_header("accept", "application/json, text/event-stream")
          |> post(
            "/mcp",
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "id" => 1,
              "method" => "initialize",
              "params" => %{
                "protocolVersion" => "2025-06-18",
                "capabilities" => %{},
                "clientInfo" => %{"name" => "t", "version" => "0"}
              }
            })
          )

        assert call.status == 200

        build_conn() |> post(~p"/oauth/revoke", %{"token" => refreshed["refresh_token"]})

        # The tokens themselves are opaque; check them explicitly too.
        Logger.flush()

        send(
          self(),
          {:tokens,
           [
             code,
             tokens["access_token"],
             tokens["refresh_token"],
             refreshed["access_token"],
             refreshed["refresh_token"],
             verifier
           ]}
        )
      end)

    assert_clean(log)
    assert_received {:tokens, plaintexts}
    for t <- plaintexts, do: refute(log =~ t, "an OAuth credential reached the log")
  end

  test "personal tokens: created in the web app and used against /mcp", %{conn: conn} do
    {user, _} = with_log(fn -> user_fixture() end)

    log =
      capture_log([level: :debug], fn ->
        {:ok, view, _} = live(log_in_user(conn, user), ~p"/clients")
        view |> element("#new-token") |> render_click()
        view |> form("#token-form", token: %{name: "logcheck", expires: "7"}) |> render_submit()
        [plaintext] = Regex.run(~r/sb_[\w-]{20,}/, render(view))

        build_conn()
        |> put_req_header("authorization", "Bearer " <> plaintext)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> post("/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}))

        {:ok, other, _} = PersonalTokens.create(Scope.for_user(user), "ctx", nil)
        {:ok, _, _} = PersonalTokens.verify(other)
        Logger.flush()
        send(self(), {:plaintexts, [plaintext, other]})
      end)

    assert_received {:plaintexts, plaintexts}
    for t <- plaintexts, do: refute(log =~ t, "a personal token reached the log")
    assert_clean(log)
  end

  test "Rocket.Chat writes as the person and as the bot user" do
    {user, _} = with_log(fn -> user_fixture(%{name: "Log Check"}) end)
    scope = Scope.for_user(user)
    stub_everything(user)
    rc_token = secret("rc-token")

    log =
      capture_log([level: :debug], fn ->
        {:ok, _} =
          Connections.link(scope, "rocketchat", %{
            "token" => rc_token,
            "user_id" => secret("rc-uid")
          })

        {:ok, _} = Tools.run(scope, "send_message", %{"to" => "#general", "text" => "hello"})
        {:ok, _} = Tools.run(scope, "notify_me", %{"text" => "done"})
        Logger.flush()
      end)

    assert_clean(log)
    refute log =~ "bot-token"
  end

  test "Rocket.Chat reads, watch notices and the Forgejo webhook keep tokens and message text out" do
    {user, _} = with_log(fn -> user_fixture(%{name: "Log Check"}) end)
    scope = Scope.for_user(user)
    rc_token = secret("rc-token")
    private = "private words #{@m}"
    room = "rLogCheck00000001"

    {:ok, _} =
      with_log(fn ->
        Repo.insert(%Connections.Connection{
          user_id: user.id,
          system: "rocketchat",
          secret: %{"token" => rc_token, "user_id" => "uLogCheck0000001"},
          status: "ok",
          identity: %{"username" => user.username},
          identity_matches: true
        })
      end)
      |> elem(0)

    message = %{
      "_id" => "mLogCheck0000001",
      "rid" => room,
      "msg" => private,
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "u" => %{"_id" => "uOther000000001", "username" => "other", "name" => "Other"}
    }

    Req.Test.stub(Switchboard.Upstreams, fn conn ->
      case conn.request_path do
        "/api/v1/subscriptions.get" ->
          Req.Test.json(conn, %{
            "update" => [%{"rid" => room, "t" => "d", "unread" => 1, "open" => true}]
          })

        "/api/v1/rooms.get" ->
          Req.Test.json(conn, %{
            "update" => [
              %{"_id" => room, "t" => "d", "uids" => ["a", "b"], "lastMessage" => message}
            ]
          })

        "/api/v1/users.info" ->
          Req.Test.json(conn, %{
            "user" => %{"username" => user.username, "name" => user.name, "type" => "user"}
          })

        "/api/v1/subscriptions.getOne" ->
          Req.Test.json(conn, %{"subscription" => %{"rid" => room, "t" => "d", "name" => "other"}})

        "/api/v1/im.history" ->
          Req.Test.json(conn, %{"messages" => [message]})

        "/api/v1/im.create" ->
          Req.Test.json(conn, %{"room" => %{"_id" => "dm1"}})

        "/api/v1/chat.postMessage" ->
          Req.Test.json(conn, %{"message" => %{"_id" => "m1"}})
      end
    end)

    log =
      capture_log([level: :debug], fn ->
        {:ok, inbox} = Tools.run(scope, "chat_inbox", %{})
        assert inbox =~ private
        {:ok, read} = Tools.run(scope, "chat_read", %{"target" => room})
        assert read =~ private

        # A watch notice whose content (release highlights) carries the marker.
        watch =
          Repo.insert!(%Switchboard.Watches.Watch{
            user_id: user.id,
            kind: "release",
            target: %{"repo" => "app"},
            subject: "app",
            expires_at: DateTime.add(DateTime.utc_now(:second), 3600)
          })

        :notified =
          Switchboard.Watches.notify(watch, %{
            "repo" => "app",
            "name" => "r1",
            "status" => "success",
            "highlights" => [private]
          })

        :ok =
          Oban.Testing.perform_job(
            Switchboard.Watches.Deliver,
            %{watch_id: watch.id, notice: "result"},
            repo: Repo
          )

        # The webhook: a bad signature is refused without logging the body or the secret.
        body =
          Jason.encode!(%{
            "run" => %{"repository" => %{"full_name" => "demo/app"}},
            "note" => private
          })

        conn =
          Phoenix.ConnTest.build_conn(:post, "/hooks/forgejo", body)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Plug.Conn.put_req_header("x-forgejo-event", "action_run_success")
          |> Plug.Conn.put_req_header("x-forgejo-signature", "0" <> secret("sig"))
          |> SwitchboardWeb.Endpoint.call([])

        assert conn.status == 401
        Logger.flush()
      end)

    assert_clean(log)
    refute log =~ rc_token
    refute log =~ "hook-secret"
    refute log =~ "bot-token"
  end
end
