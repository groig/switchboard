defmodule Switchboard.PlaneBatchTest do
  # plane_get_items (pacing, partial results), the per-person item cache, plane_set_state's
  # forgiving state names and release lookups. Synchronous: some cases change the Plane budget.
  use Switchboard.DataCase, async: false

  import Plug.Conn
  import Switchboard.OAuthFixtures
  import Switchboard.UpstreamStubs, only: [stub: 1, link_all: 1]

  alias Switchboard.{Scope, Tools}
  alias Switchboard.Plane.Budget

  @ws "/api/v1/workspaces/acme"

  setup do
    user =
      user_fixture(%{username: "ana", forgejo_id: 700_000 + System.unique_integer([:positive])})
      |> link_all()

    Budget.reset()
    on_exit(fn -> Application.delete_env(:switchboard, Budget) end)
    {:ok, scope: Scope.for_user(user, client_name: "test")}
  end

  defp budget(opts), do: Application.put_env(:switchboard, Budget, opts)

  # A small synthetic Plane: DEMO-1..DEMO-30 exist, DEMO-403 is forbidden, anything else is 404.
  # Every request is reported to the test as {:plane, method, path}. `limit_after` answers 429
  # (Retry-After: 30) once that many item reads have been served.
  defp plane(opts \\ []) do
    test = self()
    served = :counters.new(1, [])
    limit_after = opts[:limit_after]

    stub(%{
      "plane.test" => fn conn ->
        send(test, {:plane, conn.method, conn.request_path})
        plane_route(conn, conn.method, conn.request_path, served, limit_after)
      end
    })
  end

  defp plane_route(conn, "GET", @ws <> "/work-items/" <> rest, served, limit_after) do
    id = String.trim_trailing(rest, "/")
    :counters.add(served, 1, 1)

    cond do
      limit_after && :counters.get(served, 1) > limit_after ->
        conn
        |> put_resp_header("retry-after", "30")
        |> put_status(429)
        |> Req.Test.json(%{"error" => "throttled"})

      id == "DEMO-403" ->
        conn |> put_status(403) |> Req.Test.json(%{"error" => "forbidden"})

      match?("DEMO-" <> _, id) and String.to_integer(String.trim_leading(id, "DEMO-")) <= 30 ->
        n = String.trim_leading(id, "DEMO-")

        Req.Test.json(conn, %{
          "id" => "i-#{n}",
          "project" => "p-demo",
          "name" => "Task #{n}",
          "sequence_id" => String.to_integer(n),
          "priority" => "medium",
          "state" => %{"id" => "s-todo", "name" => "Todo", "group" => "unstarted"},
          "assignees" => [%{"id" => "u-ana", "display_name" => "ana"}],
          "labels" => [],
          "description_html" => "<p>" <> String.duplicate("Long spec text. ", 80) <> "</p>",
          "updated_at" => "2026-11-25T10:00:00Z"
        })

      true ->
        conn |> put_status(404) |> Req.Test.json(%{"error" => "not found"})
    end
  end

  defp plane_route(conn, "GET", @ws <> "/projects/p-demo/work-items/" <> rest, _, _) do
    cond do
      String.ends_with?(rest, "/comments/") ->
        Req.Test.json(conn, %{
          "results" => [
            %{
              "comment_html" => "<p>PR is up.</p>",
              "actor" => "u-bruno",
              "created_at" => "2026-11-25T09:00:00Z"
            }
          ]
        })

      String.ends_with?(rest, "/links/") ->
        Req.Test.json(conn, %{
          "results" => [%{"title" => "PR", "url" => "https://git.example.com/pr/1"}]
        })
    end
  end

  defp plane_route(conn, "GET", @ws <> "/members/", _, _),
    do: Req.Test.json(conn, [%{"id" => "u-bruno", "display_name" => "bruno"}])

  defp plane_route(conn, "GET", @ws <> "/projects/p-demo/states/", _, _) do
    Req.Test.json(conn, %{
      "results" => [
        %{"id" => "s-todo", "name" => "Todo", "group" => "unstarted"},
        %{"id" => "s-prog", "name" => "In Progress", "group" => "started"},
        %{"id" => "s-qa", "name" => "Qa Ready for test", "group" => "started"},
        %{"id" => "s-rdeploy", "name" => "Ready for deploy", "group" => "started"},
        %{"id" => "s-done", "name" => "Done", "group" => "completed"}
      ]
    })
  end

  defp plane_route(conn, method, _path, _, _) when method in ["POST", "PATCH"],
    do: conn |> put_status(201) |> Req.Test.json(%{"id" => "x"})

  defp item_reads do
    receive_all([])
    |> Enum.filter(fn {method, path} ->
      method == "GET" and String.starts_with?(path, @ws <> "/work-items/")
    end)
  end

  defp receive_all(acc) do
    receive do
      {:plane, method, path} -> receive_all([{method, path} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "plane_get_items" do
    test "mixed known, unknown, forbidden and malformed ids", %{scope: scope} do
      plane()

      assert {:ok, md} =
               Tools.run(scope, "plane_get_items", %{
                 "ids" => ["demo-1", "DEMO-404", "DEMO-403", "DEMO-2", "nope", "DEMO-1"]
               })

      assert md =~ "## 2 Plane work items"
      assert md =~ "### DEMO-1: Task 1"
      assert md =~ "### DEMO-2: Task 2"
      assert :binary.match(md, "DEMO-1: Task 1") < :binary.match(md, "DEMO-2: Task 2")
      assert md =~ ~s(<untrusted source="plane" item="DEMO-1">)
      assert md =~ "plane_get_item DEMO-1 has the full text"
      assert md =~ "**bruno**"
      assert md =~ "[PR](https://git.example.com/pr/1)"
      assert md =~ "**Notes**"
      assert md =~ "Plane has no work item DEMO-404"
      assert md =~ "Plane denied access to acme/DEMO-403"
      assert md =~ "nope: not a work item identifier"
      # Duplicates are read once.
      assert length(Enum.filter(item_reads(), &(elem(&1, 1) =~ "DEMO-1/"))) == 1
    end

    test "argument checks", %{scope: scope} do
      assert {:error, msg} = Tools.run(scope, "plane_get_items", %{"ids" => []})
      assert msg =~ "at least one"

      ids = for n <- 1..26, do: "DEMO-#{n}"
      assert {:error, msg} = Tools.run(scope, "plane_get_items", %{"ids" => ids})
      assert msg =~ "at most 25"

      # Agents' guesses for the argument name work too.
      plane()
      assert {:ok, md} = Tools.run(scope, "plane_get_items", %{"tasks" => ["DEMO-3"]})
      assert md =~ "### DEMO-3"
    end

    test "a 429 part-way returns what was read and a note with when to retry", %{scope: scope} do
      plane(limit_after: 3)
      ids = for n <- 1..6, do: "DEMO-#{n}"

      assert {:ok, md} = Tools.run(scope, "plane_get_items", %{"ids" => ids})
      found = Regex.scan(~r/^### (DEMO-\d+)/m, md) |> Enum.map(&List.last/1)
      assert length(found) == 3
      assert md =~ "Not read yet:"
      assert md =~ "Retry them in about 30 s with plane_get_items"

      for id <- ids -- found, do: assert(md =~ id)

      # After the 429 the key fails fast: Plane isn't asked again until the reset.
      item_reads()
      assert {:error, msg} = Tools.run(scope, "plane_get_item", %{"id" => "DEMO-9"})
      assert msg =~ "rate limit is used up"
      assert msg =~ "about 30 s"
      assert item_reads() == []
    end

    test "with a short budget it keeps the reserve and says what it skipped", %{scope: scope} do
      budget(limit: 10, reserve: 4)
      plane()
      ids = for n <- 1..4, do: "DEMO-#{n}"

      assert {:ok, md} = Tools.run(scope, "plane_get_items", %{"ids" => ids})
      assert md =~ "## 4 Plane work items"
      assert md =~ "Comments or links not read"
      # 10 a minute minus the reserve of 4: never more than 6 requests, and no 429.
      assert length(receive_all([])) <= 6
    end

    test "paces requests when the window frees up in time", %{scope: scope} do
      budget(limit: 4, reserve: 1, window_ms: 80)
      plane()

      assert {:ok, md} = Tools.run(scope, "plane_get_items", %{"ids" => ["DEMO-1", "DEMO-2"]})
      assert md =~ "## 2 Plane work items"
      refute md =~ "**Notes**"
    end
  end

  describe "the item cache" do
    test "re-reads within a minute cost nothing; a write re-reads only that task", %{scope: scope} do
      plane()
      assert {:ok, _} = Tools.run(scope, "plane_get_items", %{"ids" => ["DEMO-1", "DEMO-2"]})
      receive_all([])

      # Everything plane_get_item needs is cached by the batch.
      assert {:ok, one} = Tools.run(scope, "plane_get_item", %{"id" => "DEMO-1"})
      assert one =~ "## DEMO-1: Task 1"
      assert receive_all([]) == []

      assert {:ok, _} = Tools.run(scope, "plane_comment", %{"id" => "DEMO-1", "text" => "Done."})
      receive_all([])

      assert {:ok, _} = Tools.run(scope, "plane_get_item", %{"id" => "DEMO-1"})
      reads = receive_all([])
      assert {"GET", @ws <> "/work-items/DEMO-1/"} in reads
      assert {"GET", @ws <> "/projects/p-demo/work-items/i-1/comments/"} in reads

      # The other task is still cached.
      assert {:ok, _} = Tools.run(scope, "plane_get_item", %{"id" => "DEMO-2"})
      assert receive_all([]) == []
    end

    test "plane_set_state invalidates the task it moved", %{scope: scope} do
      plane()
      assert {:ok, _} = Tools.run(scope, "plane_get_item", %{"id" => "DEMO-5"})

      assert {:ok, _} =
               Tools.run(scope, "plane_set_state", %{"id" => "DEMO-5", "state" => "Done"})

      receive_all([])
      assert {:ok, _} = Tools.run(scope, "plane_get_item", %{"id" => "DEMO-5"})
      assert {"GET", @ws <> "/work-items/DEMO-5/"} in receive_all([])
    end
  end

  describe "plane_set_state state names" do
    defp set(scope, state),
      do: Tools.run(scope, "plane_set_state", %{"id" => "DEMO-7", "state" => state})

    test "exact and case-only matches", %{scope: scope} do
      plane()
      assert {:ok, msg} = set(scope, "In Progress")
      assert msg =~ "Todo → **In Progress**."
      refute msg =~ "closest"

      assert {:ok, msg} = set(scope, "  qa ready FOR test ")
      assert msg =~ "→ **Qa Ready for test**."
      refute msg =~ "closest"

      assert {:ok, msg} = set(scope, "inprogress")
      assert msg =~ "→ **In Progress**."
    end

    test "reordered words use the clear best match and say so", %{scope: scope} do
      plane()
      assert {:ok, msg} = set(scope, "Ready for Test QA")
      assert msg =~ "→ **Qa Ready for test** (the closest state to \"Ready for Test QA\")"
      assert_received {:plane, "PATCH", _}

      assert {:ok, msg} = set(scope, "testing")
      assert msg =~ "**Qa Ready for test**"
    end

    test "ambiguous and unknown names fail, listing candidates first", %{scope: scope} do
      plane()
      assert {:error, msg} = set(scope, "Ready")
      assert msg =~ "isn't clearly one state"
      assert msg =~ "the closest are: Ready for deploy, Qa Ready for test."
      assert msg =~ "Its states: Todo, In Progress, Qa Ready for test, Ready for deploy, Done."

      assert {:error, msg} = set(scope, "Shipped")
      assert msg =~ "is not a state of this project. Its states: Todo,"
      refute_received {:plane, "PATCH", _}
    end
  end

  describe "release lookups" do
    defp releases(list),
      do: stub(%{"releases.test" => fn conn -> Req.Test.json(conn, %{"releases" => list}) end})

    defp rel(repo, name, hours_ago) do
      %{
        "repo" => repo,
        "name" => name,
        "status" => "success",
        "startedAt" =>
          DateTime.utc_now() |> DateTime.add(-hours_ago * 3600) |> DateTime.to_iso8601(),
        "highlights" => [],
        "tasks" => []
      }
    end

    setup do
      releases([
        rel("web", "release-2026.11.26.1", 2),
        rel("api", "release-2026.11.25.3", 20),
        rel("web", "release-2026.11.20.1", 150),
        rel("worker", "release-2027.1.4.1", 200)
      ])

      :ok
    end

    test "repo as owner/name, any case, or a unique prefix", %{scope: scope} do
      for repo <- ["web", "example-org/web", "WEB", "we"] do
        assert {:ok, md} = Tools.run(scope, "release", %{"repo" => repo})
        assert md =~ "## web release-2026.11.26.1", "repo #{inspect(repo)}"
      end

      assert {:ok, md} = Tools.run(scope, "release", %{"repo" => "Work"})
      assert md =~ "## worker release-2027.1.4.1"
    end

    test "an unknown repo lists the repos with releases and explains the gap", %{scope: scope} do
      assert {:error, msg} = Tools.run(scope, "release", %{"repo" => "mobile"})
      assert msg =~ "No release of `mobile` in the last 90 days."
      assert msg =~ "| web | `release-2026.11.26.1` |"
      assert msg =~ "| api | `release-2026.11.25.3` |"
      assert msg =~ "deploy pipeline publishes releases to the release feed"
      assert msg =~ "doesn't mean nothing shipped"
      assert msg =~ "| worker | `release-2027.1.4.1` |"
    end

    test "a version given as the repo or name suggests release names", %{scope: scope} do
      assert {:error, msg} = Tools.run(scope, "release", %{"repo" => "27.1"})
      assert msg =~ "Did you mean the release `release-2027.1.4.1`?"

      assert {:error, msg} = Tools.run(scope, "release", %{"name" => "2026.11.2"})
      assert msg =~ "Did you mean `release-2026.11.26.1` or `release-2026.11.25.3`"

      assert {:error, msg} =
               Tools.run(scope, "release", %{"repo" => "web", "name" => "release-2026.11.26"})

      assert msg =~ "No release named `release-2026.11.26` of `web`"
      assert msg =~ "Did you mean `release-2026.11.26.1` or"
      assert msg =~ "Latest releases of `web`: `release-2026.11.26.1`, `release-2026.11.20.1`."
    end

    test "a repo given as the name shows its latest release", %{scope: scope} do
      assert {:ok, md} = Tools.run(scope, "release", %{"name" => "api"})
      assert md =~ "`api` is a repo, not a release name"
      assert md =~ "## api release-2026.11.25.3"
    end
  end
end
