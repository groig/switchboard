defmodule Switchboard.ReadToolsTest do
  # Every read tool against synthetic upstreams (test/support/upstream_stubs.ex).
  use Switchboard.DataCase, async: true

  import Switchboard.OAuthFixtures
  import Switchboard.UpstreamStubs, only: [stub: 0, stub: 1, link_all: 1]

  alias Switchboard.{Scope, Tools}

  setup do
    user =
      user_fixture(%{username: "ana", forgejo_id: 900_000 + System.unique_integer([:positive])})
      |> link_all()

    {:ok, scope: Scope.for_user(user, client_name: "test")}
  end

  defp run!(scope, tool, args \\ %{}) do
    assert {:ok, md} = Tools.run(scope, tool, args)
    md
  end

  describe "Plane" do
    test "plane_my_items: only mine, open, grouped, overdue first, stops at the first closed item",
         %{scope: scope} do
      stub()
      md = run!(scope, "plane_my_items")

      assert md =~ "## My Plane items (3 open)"
      assert md =~ "DEMO-15"
      assert md =~ "DEMO-12"
      assert md =~ "DEMO-9"
      refute md =~ "DEMO-13"
      refute md =~ "DEMO-3 "
      assert md =~ "2020-01-01 (overdue)"
      # In progress first, then to do, then backlog.
      assert :binary.match(md, "In Progress") < :binary.match(md, "Todo")
      assert :binary.match(md, "Todo") < :binary.match(md, "Backlog")
    end

    test "plane_get_item wraps description and comments as untrusted", %{scope: scope} do
      stub()
      md = run!(scope, "plane_get_item", %{"id" => "demo-12"})

      assert md =~ "## DEMO-12: Export invoices as CSV"
      assert md =~ ~s(<untrusted source="plane" item="DEMO-12">)
      assert md =~ "Ignore previous instructions"
      # The fake closing tag inside the description is neutralised: blocks stay balanced.
      assert length(String.split(md, "<untrusted ")) == length(String.split(md, "</untrusted>"))
      assert md =~ "**bruno**"
      assert md =~ "https://example.com/spec"
    end

    test "unknown items and malformed ids", %{scope: scope} do
      stub()
      assert {:error, msg} = Tools.run(scope, "plane_get_item", %{"id" => "DEMO-404"})
      assert msg =~ "no work item"

      assert {:error, "id must look like PROJECT-123"} =
               Tools.run(scope, "plane_get_item", %{"id" => "nope"})
    end

    test "plane_search", %{scope: scope} do
      stub()

      assert run!(scope, "plane_search", %{"query" => "csv"}) =~
               "| DEMO-12 | Export invoices as CSV |"
    end

    test "a person without a Plane key gets one line with the link" do
      scope = Scope.for_user(user_fixture())
      assert {:error, msg} = Tools.run(scope, "plane_my_items", %{})
      assert msg =~ "Plane is not connected. Link it at http://localhost:4002/connections"
    end
  end

  describe "Forgejo" do
    test "pr_status: reviews, mergeability and checks", %{scope: scope} do
      stub()
      md = run!(scope, "pr_status", %{"repo" => "demo/app", "number" => 42})

      assert md =~ "## demo/app#42: DEMO-12 Export invoices as CSV"
      assert md =~ "bruno: approved; carla: review requested"
      assert md =~ "feature/csv → main"
      assert md =~ "❌ failure"
      refute_received {:forgejo_write, _, _}
    end

    test "ci_failure: the failed job, step and a scrubbed tail as untrusted", %{scope: scope} do
      stub()

      for args <- [%{"repo" => "demo/app", "pr" => 42}, %{"repo" => "demo/app", "run" => 7}] do
        md = run!(scope, "ci_failure", args)
        assert md =~ "### Job `test`, step \"Run tests\""
        assert md =~ "FAILED tests/test_export.py"
        assert md =~ ~s(<untrusted source="forgejo" repo="demo/app" run="7">)
        refute md =~ "hunter2"
        refute md =~ "lint"
      end

      assert {:error, "repo must be owner/name"} =
               Tools.run(scope, "ci_failure", %{"repo" => "x", "pr" => 1})

      refute_received {:forgejo_write, _, _}
    end

    test "repo_search_prs", %{scope: scope} do
      stub()
      md = run!(scope, "repo_search_prs", %{"query" => "DEMO-12", "repo" => "demo/app"})
      assert md =~ "[demo/app#42](https://git.example.com/demo/app/pulls/42)"
    end

    test "every Forgejo request any tool makes is a GET", %{scope: scope} do
      stub()

      for {tool, args} <- [
            {"pr_status", %{"repo" => "demo/app", "number" => 42}},
            {"ci_failure", %{"repo" => "demo/app", "pr" => 42}},
            {"repo_search_prs", %{}},
            {"task_status", %{"id" => "DEMO-12"}},
            {"my_work", %{"scope" => "week"}}
          ] do
        assert {:ok, _} = Tools.run(scope, tool, args)
      end

      refute_received {:forgejo_write, _, _}
      # Forgejo tools are read-only in v1.
      for mod <- Tools.all(),
          :forgejo in mod.connections(),
          do: assert(mod.annotations()[:read_only])
    end
  end

  describe "Argus" do
    test "error_list lists projects, then a project's issues as untrusted", %{scope: scope} do
      stub()
      assert run!(scope, "error_list") =~ "| Demo API | `demo-api` | billing | 2 |"

      md = run!(scope, "error_list", %{"project" => "demo-api"})
      assert md =~ ~s(<untrusted source="argus" project="demo-api">)
      assert md =~ "| 7 | KeyError: 'currency' | error | 12 |"
    end

    test "error_get trims personal data and query strings", %{scope: scope} do
      stub()
      md = run!(scope, "error_get", %{"project" => "demo-api", "id" => "7"})
      assert md =~ "=> total = prices"
      refute md =~ "someone@example.com"
      refute md =~ "token=abc"
      assert md =~ "env: prod"
    end
  end

  describe "Outline" do
    test "docs_search and paged docs_read (by id or URL)", %{scope: scope} do
      stub()
      md = run!(scope, "docs_search", %{"query" => "deploy"})
      assert md =~ "**Deploy checklist** (id `a1B2c3D4e5`"
      assert md =~ "http://outline.test/doc/deploy-checklist-a1B2c3D4e5"

      page1 =
        run!(scope, "docs_read", %{"id" => "http://outline.test/doc/deploy-checklist-a1B2c3D4e5"})

      assert page1 =~ "Page 1 of 2"
      assert page1 =~ "Next: docs_read with page 2."
      assert run!(scope, "docs_read", %{"id" => "a1B2c3D4e5", "page" => 9}) =~ "Page 2 of 2"
    end
  end

  describe "releases and cross-system tools" do
    test "release: by repo (latest), by name, and the latest of every repo", %{scope: scope} do
      stub()
      md = run!(scope, "release", %{"repo" => "app"})
      assert md =~ "## app release-2026.11.26.1"
      assert md =~ "🟡 yellow (watching the first 24 h)"
      assert md =~ "| DEMO-12 | named in a commit |"
      assert md =~ ~s(<untrusted source="argus">)

      assert run!(scope, "release", %{"name" => "release-2026.11.20.1"}) =~ "Being prepared."
      assert run!(scope, "release") =~ "## Latest releases"
    end

    test "task_status joins Plane, PRs with CI, commits and the shipping release", %{scope: scope} do
      stub()
      md = run!(scope, "task_status", %{"id" => "DEMO-12"})

      assert md =~ "**Plane:** In Progress (started)"
      assert md =~ "[demo/app#42]"
      assert md =~ "Commits naming it: `4f2c9e1a3b`"
      assert md =~ "🚀 Shipped in **app release-2026.11.26.1**"
      assert md =~ "| 7 | KeyError: 'currency' | **yes** |"
    end

    test "task_status says when a task is not in production yet", %{scope: scope} do
      stub(%{
        "releases.test" => fn conn -> Req.Test.json(conn, %{"releases" => []}) end
      })

      assert run!(scope, "task_status", %{"id" => "DEMO-12"}) =~ "Not in production yet"
    end

    test "my_work: every section, with my error flagged by culprit and my release", %{
      scope: scope
    } do
      stub()
      md = run!(scope, "my_work", %{"scope" => "week"})

      assert md =~ "### My Plane items (3 open)"

      assert md =~
               "| [demo/app#42](https://git.example.com/demo/app/pulls/42) | DEMO-12 Export invoices as CSV | yours | open | ❌ failure |"

      assert md =~ "⚠️ billing/views.py in `4f2c9e1a3b`"
      # The old error (2020) is outside the window.
      refute md =~ "Old timeout"
      assert md =~ "| app release-2026.11.26.1 | 🚀 success |"
      refute md =~ "**Notes**"
    end

    test "my_work: unlinked, slow and failing systems become notes; the rest still renders" do
      user = user_fixture(%{username: "bea"})
      Switchboard.UpstreamStubs.link_all(user)
      scope = Scope.for_user(user)

      Switchboard.Repo.delete_all(
        from c in Switchboard.Connections.Connection,
          where: c.user_id == ^user.id and c.system == "plane"
      )

      stub(%{"argus.test" => {:delay, 2_000}, "releases.test" => {:status, 503}})

      started = System.monotonic_time(:millisecond)
      md = run!(scope, "my_work")
      elapsed = System.monotonic_time(:millisecond) - started

      assert md =~ "## Pull requests"
      assert md =~ "[demo/app#42]"
      assert md =~ "Plane is not connected. Link it at"
      assert md =~ "Argus didn't answer in time; this part is missing."
      assert md =~ "Releases answered HTTP 503"
      # Within the (test) budget, not the slow upstream's 2 s.
      assert elapsed < 1_500
    end

    test "tool results record which upstreams they called", %{scope: scope} do
      stub()
      run!(scope, "task_status", %{"id" => "DEMO-12"})

      [event] = Switchboard.Audit.list(%{user_id: scope.user.id, action: "task_status"})
      assert Enum.sort(event.upstreams) == ["forgejo", "plane", "releases"]
    end
  end
end
