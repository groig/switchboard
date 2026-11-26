defmodule Switchboard.WriteToolsTest do
  # Write tools and notify_me against synthetic upstreams, plus the policy matrix.
  use Switchboard.DataCase, async: true

  import Switchboard.OAuthFixtures
  import Switchboard.UpstreamStubs, only: [stub: 0, link_all: 1]

  alias Switchboard.{Controls, Scope, Tools}
  alias Switchboard.Connections.Connection

  setup do
    user =
      user_fixture(%{
        username: "ana",
        name: "Ana García",
        forgejo_id: 800_000 + System.unique_integer([:positive])
      })
      |> link_all()

    Repo.insert!(%Connection{
      user_id: user.id,
      system: "rocketchat",
      secret: %{"token" => "rc-personal-#{user.id}", "user_id" => "rc-uid-ana"},
      status: "ok",
      identity: %{"username" => "ana"},
      identity_matches: true
    })

    admin = %{user_fixture() | admin: true}

    {:ok,
     scope: Scope.for_user(user, client_name: "test"), user: user, admin: Scope.for_user(admin)}
  end

  @writes %{
    "plane_comment" => {%{"id" => "DEMO-12", "text" => "Ready for QA"}, :plane},
    "plane_set_state" => {%{"id" => "DEMO-12", "state" => "in review"}, :plane},
    "error_resolve" => {%{"project" => "demo-api", "id" => "7"}, :argus},
    "error_ignore" => {%{"project" => "demo-api", "id" => "7"}, :argus},
    "docs_draft" => {%{"title" => "QA handoff", "text" => "## Steps"}, :outline},
    "send_message" => {%{"to" => "#demo-dev", "text" => "Ready for QA"}, :rocketchat},
    "notify_me" => {%{"text" => "CI passed"}, nil}
  }

  test "every write tool in the registry is covered by the policy matrix below" do
    writes =
      for mod <- Tools.all(),
          not mod.annotations()[:read_only],
          not String.starts_with?(mod.name(), "test_"),
          do: mod.name()

    assert Enum.sort(writes) == Enum.sort(Map.keys(@writes))
  end

  describe "policy matrix" do
    for {tool, {args, system}} <- @writes do
      if system do
        test "#{tool} refuses without the person's own #{system} connection and never falls back",
             %{user: user} do
          stub()

          Repo.delete_all(
            from c in Connection,
              where: c.user_id == ^user.id and c.system == ^Atom.to_string(unquote(system))
          )

          scope = Scope.for_user(user)

          assert {:error, msg} = Tools.run(scope, unquote(tool), unquote(Macro.escape(args)))
          assert msg =~ "not connected"
          refute_received {:upstream_write, _, _, _, _, _}
        end
      end

      test "#{tool} is blocked by read-only mode", %{scope: scope, admin: admin} do
        stub()
        {:ok, _} = Controls.update_global(admin, %{read_only: true})
        assert {:error, msg} = Tools.run(scope, unquote(tool), unquote(Macro.escape(args)))
        assert msg =~ "read-only"
        refute_received {:upstream_write, _, _, _, _, _}
        refute Enum.any?(Tools.available(scope), &(&1.name() == unquote(tool)))
      end

      test "#{tool} is blocked by its kill switch", %{scope: scope, admin: admin} do
        stub()
        {:ok, _} = Controls.update_tool(admin, unquote(tool), %{enabled: false})
        assert {:error, msg} = Tools.run(scope, unquote(tool), unquote(Macro.escape(args)))
        assert msg =~ "turned off"
        refute_received {:upstream_write, _, _, _, _, _}
      end

      test "#{tool} writes with the person's own credential only (or, for notify_me, only to the caller)",
           %{scope: scope, user: user} do
        stub()
        assert {:ok, _} = Tools.run(scope, unquote(tool), unquote(Macro.escape(args)))
        assert_received {:upstream_write, host, _method, _path, creds, body}

        case unquote(system) do
          :plane -> assert creds["x-api-key"] == "plane-key-#{user.id}"
          :argus -> assert creds["authorization"] == "Bearer argus_key"
          :outline -> assert creds["authorization"] == "Bearer ol-key"
          :rocketchat -> assert creds["x-auth-token"] == "rc-personal-#{user.id}"
          nil -> assert creds["x-auth-token"] == "bot-token" and body["username"] == "ana"
        end

        # Nothing anywhere uses the bot token except notify_me.
        if unquote(system), do: refute(Enum.any?(Map.values(creds), &(&1 =~ "bot-token")))
        assert host in ~w(plane.test argus.test outline.test chat.test)
      end
    end

    test "every write tool description asks for confirmation and annotates as a write" do
      for name <- Map.keys(@writes) do
        {:ok, mod} = Tools.fetch(name)
        refute mod.annotations()[:read_only]
        assert mod.description() =~ ~r/confirm/i
      end
    end
  end

  describe "plane" do
    test "plane_comment posts escaped HTML to the right item", %{scope: scope} do
      stub()

      assert {:ok, msg} =
               Tools.run(scope, "plane_comment", %{"id" => "demo-12", "text" => "a <b>\n\nsecond"})

      assert msg =~ "Commented on DEMO-12"
      assert_received {:upstream_write, "plane.test", "POST", path, _, %{"comment_html" => html}}
      assert path =~ "/work-items/i-12/comments/"
      assert html == "<p>a &lt;b&gt;</p><p>second</p>"
    end

    test "plane_set_state validates the name and returns old and new state", %{scope: scope} do
      stub()

      assert {:ok, msg} =
               Tools.run(scope, "plane_set_state", %{"id" => "DEMO-12", "state" => "In Review"})

      assert msg =~ "In Progress → **In Review**"
      assert_received {:upstream_write, "plane.test", "PATCH", _, _, %{"state" => "s-review"}}

      assert {:error, msg} =
               Tools.run(scope, "plane_set_state", %{"id" => "DEMO-12", "state" => "Shipped"})

      assert msg =~
               "is not a state of this project. Its states: Todo, In Progress, In Review, Done."

      assert {:ok, msg} =
               Tools.run(scope, "plane_set_state", %{"id" => "DEMO-12", "state" => "in progress"})

      assert msg =~ "already in **In Progress**"
    end

    test "a Plane 429 is explained plainly", %{scope: scope} do
      Switchboard.UpstreamStubs.stub(%{"plane.test" => {:status, 429}})
      assert {:error, msg} = Tools.run(scope, "plane_my_items", %{})
      assert msg =~ "rate limit is used up"
    end

    test "repeated reads are served from the per-person cache; writes clear it", %{scope: scope} do
      stub()
      assert {:ok, first} = Tools.run(scope, "plane_my_items", %{})

      # Within the cache window Plane isn't called again.
      Req.Test.stub(Switchboard.Upstreams, fn _conn -> raise "Plane must not be called again" end)
      assert {:ok, ^first} = Tools.run(scope, "plane_my_items", %{})

      # A write drops the person's cached reads: the next read goes to Plane.
      stub()
      assert {:ok, _} = Tools.run(scope, "plane_comment", %{"id" => "DEMO-12", "text" => "x"})
      test = self()

      Req.Test.stub(Switchboard.Upstreams, fn conn ->
        send(test, {:plane_called, conn.request_path})
        conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{})
      end)

      Tools.run(scope, "plane_my_items", %{})
      assert_received {:plane_called, _}
    end
  end

  describe "argus, outline" do
    test "error_resolve and error_ignore", %{scope: scope} do
      stub()

      assert {:ok, msg} =
               Tools.run(scope, "error_resolve", %{"project" => "demo-api", "id" => "7"})

      assert msg =~ "now **resolved**"

      assert_received {:upstream_write, "argus.test", "POST",
                       "/api/v1/projects/demo-api/issues/7/resolve", _, _}

      assert {:ok, msg} =
               Tools.run(scope, "error_ignore", %{"project" => "demo-api", "id" => "7"})

      assert msg =~ "now **ignored**"

      assert {:error, _} =
               Tools.run(scope, "error_ignore", %{"project" => "demo-api", "id" => "../x"})
    end

    test "docs_draft always asks for a draft and refuses to report a published document", %{
      scope: scope
    } do
      stub()
      assert {:ok, msg} = Tools.run(scope, "docs_draft", %{"title" => "QA", "text" => "x"})
      assert msg =~ "not published"

      assert_received {:upstream_write, "outline.test", "POST", "/api/documents.create", _,
                       %{"publish" => false}}

      Switchboard.UpstreamStubs.stub(%{
        "outline.test" => fn conn ->
          Req.Test.json(conn, %{
            "data" => %{
              "title" => "QA",
              "url" => "/doc/x",
              "publishedAt" => "2026-11-26T10:00:00Z"
            }
          })
        end
      })

      assert {:error, msg} = Tools.run(scope, "docs_draft", %{"title" => "QA", "text" => "x"})
      assert msg =~ "published the document"
    end
  end

  describe "send_message" do
    test "posts to a channel the person belongs to, or a person", %{scope: scope} do
      stub()

      assert {:ok, "Sent to #demo-dev as you: http://chat.test/channel/demo-dev?msg=m-1"} =
               Tools.run(scope, "send_message", %{"to" => "#demo-dev", "text" => "hi"})

      assert {:ok, msg} = Tools.run(scope, "send_message", %{"to" => "@bruno", "text" => "hi"})
      assert msg =~ "Sent to @bruno"
    end

    test "refuses @all/@here/@everyone, channels the person isn't in, unknown channels and long texts",
         %{scope: scope} do
      stub()

      for text <- ["@all deploy now", "hey @here", "(@everyone)", "ping @HERE please"] do
        assert {:error, msg} =
                 Tools.run(scope, "send_message", %{"to" => "#demo-dev", "text" => text})

        assert msg =~ "not allowed"
      end

      # An email address or a handle containing "all" is fine.
      assert {:ok, _} =
               Tools.run(scope, "send_message", %{
                 "to" => "#demo-dev",
                 "text" => "mail ana@all.example.com, cc @allison"
               })

      assert {:error, msg} =
               Tools.run(scope, "send_message", %{"to" => "#secret", "text" => "hi"})

      assert msg =~ "not a member"
      assert {:error, msg} = Tools.run(scope, "send_message", %{"to" => "#nope", "text" => "hi"})
      assert msg =~ "no channel"

      assert {:error, msg} =
               Tools.run(scope, "send_message", %{
                 "to" => "#demo-dev",
                 "text" => String.duplicate("a", 4_001)
               })

      assert msg =~ "longer than"

      refute_received {:upstream_write, "chat.test", "POST", "/api/v1/chat.postMessage", _,
                       %{"roomId" => "r-secret"}}
    end

    test "the message text is not stored in the audit log", %{scope: scope} do
      stub()
      Tools.run(scope, "send_message", %{"to" => "#demo-dev", "text" => "private words"})
      [event] = Switchboard.Audit.list(%{user_id: scope.user.id, action: "send_message"})
      assert event.args == %{"to" => "#demo-dev", "text" => "[redacted]"}
    end
  end

  describe "notify_me" do
    test "a DM from the bot user to the caller only, without mentions, with the notice line in their language",
         %{scope: scope, user: user} do
      stub()
      assert {:ok, msg} = Tools.run(scope, "notify_me", %{"text" => "Build done @bruno @all"})
      assert msg =~ "(as @ana)"

      assert_received {:upstream_write, "chat.test", "POST", "/api/v1/im.create",
                       %{"x-auth-token" => "bot-token"}, %{"username" => "ana"}}

      assert_received {:upstream_write, "chat.test", "POST", "/api/v1/chat.postMessage", _,
                       %{"roomId" => "dm-ana", "text" => text}}

      refute text =~ "@bruno"
      refute text =~ "@all"
      assert text =~ "Build done"
      # Default profile language is Spanish.
      assert user.locale == "es"
      assert text =~ "Aviso automático de Switchboard. Las respuestas aquí no se leen."
    end

    test "English notice line for English profiles", %{user: user} do
      user = user |> Ecto.Changeset.change(locale: "en") |> Repo.update!()
      stub()
      assert {:ok, _} = Tools.run(Scope.for_user(user), "notify_me", %{"text" => "x"})

      assert_received {:upstream_write, "chat.test", "POST", "/api/v1/chat.postMessage", _,
                       %{"text" => text}}

      assert text =~ "Automatic notice from Switchboard. Replies here aren't read."
    end

    test "without a linked Rocket.Chat key, the Forgejo username is used only if the name matches",
         %{user: ana} do
      stub()

      Repo.delete_all(
        from c in Connection, where: c.user_id == ^ana.id and c.system == "rocketchat"
      )

      assert {:ok, _} = Tools.run(Scope.for_user(ana), "notify_me", %{"text" => "x"})

      assert_received {:upstream_write, "chat.test", "POST", "/api/v1/im.create", _,
                       %{"username" => "ana"}}

      # "bea" exists in Rocket.Chat with someone else's name: refused, nobody is messaged.
      bea = user_fixture(%{username: "bea", name: "Bea Ruiz"})
      flush_writes()
      assert {:error, msg} = Tools.run(Scope.for_user(bea), "notify_me", %{"text" => "x"})
      assert msg =~ "can't tell which Rocket.Chat user is you"
      refute_received {:upstream_write, _, _, _, _, _}
    end

    test "is capped in length and per hour", %{scope: scope} do
      stub()

      assert {:error, msg} =
               Tools.run(scope, "notify_me", %{"text" => String.duplicate("a", 1_001)})

      assert msg =~ "longer than"

      for _ <- 1..30,
          do: Switchboard.RateLimit.take({scope.user.id, :notify_me_hour}, 30, :timer.hours(1))

      assert {:error, msg} = Tools.run(scope, "notify_me", %{"text" => "x"})
      assert msg =~ "30 messages an hour"
    end
  end

  defp flush_writes do
    receive do
      {:upstream_write, _, _, _, _, _} -> flush_writes()
    after
      0 -> :ok
    end
  end
end
