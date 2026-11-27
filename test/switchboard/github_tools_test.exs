defmodule Switchboard.GitHubToolsTest do
  # Repository tools, joins and routing against a synthetic GitHub (test/support/upstream_stubs.ex):
  # example-org is a GitHub owner (config/test.exs), everything else is Forgejo.
  use Switchboard.DataCase, async: true

  import Switchboard.OAuthFixtures
  import Switchboard.UpstreamStubs, only: [stub: 0, stub: 1, link_all: 1, link_github: 1]

  alias Switchboard.{Audit, Repos, Scope, Tools, Upstreams, Workflows}
  alias Switchboard.Repos.Ref

  @app_settings "http://github.test/settings/connections/applications/gh-client"

  setup do
    user =
      user_fixture(%{username: "ana", forgejo_id: 900_000 + System.unique_integer([:positive])})
      |> link_all()

    {:ok, user: user, scope: Scope.for_user(user, client_name: "test")}
  end

  defp with_github(%{user: user}) do
    link_github(user)
    :ok
  end

  defp run!(scope, tool, args) do
    assert {:ok, md} = Tools.run(scope, tool, args)
    md
  end

  defp github_requests(acc \\ []) do
    receive do
      {:github, host, method, path, auth} -> github_requests([{host, method, path, auth} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "routing" do
    test "owner/repo goes to GitHub for GITHUB_OWNERS (any case), to Forgejo otherwise" do
      assert {:ok, %Ref{host: :github, owner: "example-org", name: "example-repo"}} =
               Repos.resolve("example-org/example-repo")

      assert {:ok, %Ref{host: :github}} = Repos.resolve(" Example-Org/example-repo ")
      assert {:ok, %Ref{host: :forgejo, owner: "demo"}} = Repos.resolve("demo/app")
      # Stored watch targets: bare means Forgejo whatever the owners say.
      assert {:ok, %Ref{host: :forgejo}} =
               Repos.resolve("example-org/example-repo", default: :forgejo)
    end

    test "explicit prefixes win over the owner list" do
      assert {:ok, %Ref{host: :github, owner: "someone"}} = Repos.resolve("github:someone/tool")
      assert {:ok, %Ref{host: :forgejo}} = Repos.resolve("forgejo:example-org/example-repo")
      assert {:ok, %Ref{host: :github}} = Repos.resolve("GitHub:someone/tool")
    end

    test "URLs route by host and keep the PR or run number" do
      assert {:ok, %Ref{host: :github, owner: "example-org", name: "example-repo", pr: 7}} =
               Repos.resolve("http://github.test/example-org/example-repo/pull/7/files")

      assert {:ok, %Ref{host: :github, run: 4242, pr: nil}} =
               Repos.resolve("http://github.test/example-org/example-repo/actions/runs/4242")

      assert {:ok, %Ref{host: :github, name: "example-repo"}} =
               Repos.resolve("http://api.github.test/repos/example-org/example-repo")

      assert {:ok, %Ref{host: :github, name: "example-repo"}} =
               Repos.resolve("http://github.test/example-org/example-repo.git")

      assert {:ok, %Ref{host: :forgejo, owner: "demo", name: "app", pr: 42}} =
               Repos.resolve("http://forgejo.test/demo/app/pulls/42")

      assert {:error, msg} = Repos.resolve("https://gitlab.example/demo/app")
      assert msg =~ "gitlab.example is neither this Switchboard's Forgejo"

      assert {:error, msg} = Repos.resolve("http://github.test/example-org")
      assert msg =~ "isn't a repository URL"
    end

    test "malformed repos" do
      for bad <- ["", "x", "a/b/c", "github:", "owner/re po", nil] do
        assert {:error, "repo must be owner/name" <> _} = Repos.resolve(bad)
      end
    end
  end

  describe "GitHub tools" do
    setup :with_github

    test "pr_status maps reviews, mergeability and check runs plus commit statuses", %{
      scope: scope
    } do
      stub()
      md = run!(scope, "pr_status", %{"repo" => "example-org/example-repo", "number" => 7})

      assert md =~ "## example-org/example-repo#7: DEMO-12 Export invoices from the GitHub app"
      assert md =~ "carla-gh: changes requested"
      assert md =~ "bea: review requested"
      assert md =~ "example-org/backend (team): review requested"
      # Comments aren't a review decision.
      refute md =~ "dan-gh"
      assert md =~ "| Mergeable | no (blocked: required reviews or checks missing) |"
      assert md =~ "DEMO-12-export → main"
      assert md =~ "Overall: **❌ failure**"
      assert md =~ "| test | ❌ failure | Process completed with exit code 1."
      assert md =~ "| lint | ✅ success |"
      assert md =~ "| coverage | ✅ success | 92% covered |"
      refute_received {:github_write, _, _}
    end

    test "a pull request URL stands for repo and number", %{scope: scope} do
      stub()

      md =
        run!(scope, "pr_status", %{
          "repo" => "http://github.test/example-org/example-repo/pull/7"
        })

      assert md =~ "## example-org/example-repo#7"
    end

    test "ci_failure: the failed job and step, a scrubbed log excerpt, fetched without the token",
         %{scope: scope} do
      stub()

      for args <- [
            %{"repo" => "example-org/example-repo", "pr" => 7},
            %{"repo" => "example-org/example-repo", "run" => 4242},
            %{"repo" => "http://github.test/example-org/example-repo/actions/runs/4242"}
          ] do
        md = run!(scope, "ci_failure", args)
        assert md =~ "## CI failure: example-org/example-repo run #4242"
        assert md =~ "| Workflow | ci.yml (pull_request) |"
        assert md =~ "### Job `test`, step \"Run tests\""
        assert md =~ ~s(<untrusted source="github" repo="example-org/example-repo" run="4242">)
        assert md =~ "1) test exports invoices (Example.ExportTest)"
        assert md =~ "212 tests, 1 failure"
        # Only the failing step, without markers, timestamps or secrets.
        refute md =~ "Checked out"
        refute md =~ "Post job cleanup"
        refute md =~ "##[group]"
        refute md =~ "09:05:10"
        refute md =~ "hunter2"
        refute md =~ "ghs_abcdef"
        refute md =~ "lint"
      end

      requests = github_requests()

      assert {"logs.github.test", "GET", "/jobs/9001.txt", []} =
               Enum.find(requests, &(elem(&1, 0) == "logs.github.test"))

      assert Enum.all?(
               for({"api.github.test", _, _, auth} <- requests, do: auth),
               &match?(["Bearer gho_test-" <> _], &1)
             )

      refute_received {:github_write, _, _}
    end

    test "repo_search_prs in a GitHub repo, and across both hosts without repo", %{scope: scope} do
      stub()

      md = run!(scope, "repo_search_prs", %{"repo" => "example-org/example-repo"})

      assert md =~
               "[example-org/example-repo#7](https://github.example/example-org/example-repo/pull/7)"

      refute md =~ "demo/app"

      md = run!(scope, "repo_search_prs", %{"query" => "DEMO-12"})
      assert md =~ "[demo/app#42](https://git.example.com/demo/app/pulls/42)"
      assert md =~ "[example-org/example-repo#7]"
      # Only the configured owners are searched on GitHub.
      assert Enum.any?(github_requests(), fn {_, _, path, _} -> path == "/search/issues" end)
    end

    test "every GitHub request any tool makes is a GET", %{scope: scope} do
      stub()

      for {tool, args} <- [
            {"pr_status", %{"repo" => "example-org/example-repo", "number" => 7}},
            {"ci_failure", %{"repo" => "example-org/example-repo", "pr" => 7}},
            {"repo_search_prs", %{}},
            {"repo_search_prs", %{"repo" => "example-org/example-repo"}},
            {"task_status", %{"id" => "DEMO-12"}},
            {"my_work", %{"scope" => "week"}}
          ] do
        assert {:ok, _} = Tools.run(scope, tool, args)
      end

      requests = github_requests()
      assert length(requests) > 10
      assert Enum.all?(requests, &(elem(&1, 1) == "GET"))
      refute_received {:github_write, _, _}

      for mod <- Tools.all(),
          :github in mod.connections(),
          mod.name() != "watch_ci",
          do: assert(mod.annotations()[:read_only])
    end

    test "org approval missing: a 404 for the repo says the org may need to approve the app",
         %{scope: scope} do
      stub()

      assert {:error, msg} =
               Tools.run(scope, "pr_status", %{
                 "repo" => "example-org/private-repo",
                 "number" => 1
               })

      assert msg =~ "`example-org/private-repo` isn't visible to your GitHub account"
      assert msg =~ "an owner of `example-org` may need to approve the Switchboard app"
      assert msg =~ @app_settings

      # A 403 too, and search's 422 for a repository it can't see.
      stub(%{
        "api.github.test" => fn conn ->
          conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => "Forbidden"})
        end
      })

      assert {:error, msg} =
               Tools.run(scope, "ci_failure", %{"repo" => "example-org/private-repo", "run" => 1})

      assert msg =~ "may need to approve the Switchboard app"

      stub()

      assert {:error, msg} =
               Tools.run(scope, "repo_search_prs", %{"repo" => "example-org/private-repo"})

      assert msg =~ "may need to approve the Switchboard app"
    end

    test "a renamed repository's 301 is followed once on the API host", %{scope: scope} do
      stub(%{
        "api.github.test" => fn conn ->
          case conn.request_path do
            "/repos/example-org/old-name/pulls/7" ->
              conn
              |> Plug.Conn.put_resp_header(
                "location",
                "http://api.github.test/repos/example-org/example-repo/pulls/7"
              )
              |> Plug.Conn.send_resp(301, "")

            _ ->
              Switchboard.UpstreamStubs.github(conn)
          end
        end
      })

      assert run!(scope, "pr_status", %{"repo" => "example-org/old-name", "number" => 7}) =~
               "| Mergeable | no (blocked"
    end

    test "a missing PR in a visible repo is just missing", %{scope: scope} do
      stub()

      assert {:error, "No pull request example-org/example-repo#99, or you can't see it."} =
               Tools.run(scope, "pr_status", %{
                 "repo" => "example-org/example-repo",
                 "number" => 99
               })
    end

    test "rate limited: the reset time, then fail fast without asking GitHub", %{scope: scope} do
      reset = System.os_time(:second) + 300

      stub(%{
        "api.github.test" => fn conn ->
          conn
          |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
          |> Plug.Conn.put_resp_header("x-ratelimit-reset", to_string(reset))
          |> Plug.Conn.put_status(403)
          |> Req.Test.json(%{"message" => "API rate limit exceeded"})
        end
      })

      args = %{"repo" => "example-org/example-repo", "number" => 7}
      assert {:error, msg} = Tools.run(scope, "pr_status", args)
      assert msg =~ "GitHub's rate limit for your account is used up"
      assert msg =~ "resets in about 5 minutes"
      _ = github_requests()

      assert {:error, msg} = Tools.run(scope, "pr_status", args)
      assert msg =~ "resets in about 5 minutes"
      assert github_requests() == []
    end

    test "Retry-After (secondary rate limit)", %{scope: scope} do
      stub(%{
        "api.github.test" => fn conn ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", "30")
          |> Plug.Conn.put_status(429)
          |> Req.Test.json(%{})
        end
      })

      assert {:error, msg} =
               Tools.run(scope, "pr_status", %{
                 "repo" => "example-org/example-repo",
                 "number" => 7
               })

      assert msg =~ "resets in about a minute"
    end

    test "single sign-on enforcement links the authorization page", %{user: user} do
      # A separate token, so the previous test's limit doesn't apply.
      scope = Scope.for_user(user)
      sso = "http://github.test/orgs/example-org/sso?authorization_request=abc"

      stub(%{
        "api.github.test" => fn conn ->
          conn
          |> Plug.Conn.put_resp_header("x-github-sso", "required; url=#{sso}")
          |> Plug.Conn.put_status(403)
          |> Req.Test.json(%{})
        end
      })

      assert {:error, msg} =
               Tools.run(scope, "pr_status", %{
                 "repo" => "example-org/example-repo",
                 "number" => 7
               })

      assert msg =~ "requires single sign-on"
      assert msg =~ sso
    end

    test "ETags: a 304 reuses the cached body", %{scope: scope} do
      test = self()

      stub(%{
        "api.github.test" => fn conn ->
          case Plug.Conn.get_req_header(conn, "if-none-match") do
            [~s("v1")] ->
              send(test, :conditional)
              Plug.Conn.send_resp(conn, 304, "")

            _ ->
              conn
              |> Plug.Conn.put_resp_header("etag", ~s("v1"))
              |> Switchboard.UpstreamStubs.github()
          end
        end
      })

      args = %{"repo" => "example-org/example-repo", "number" => 7}
      first = run!(scope, "pr_status", args)
      assert run!(scope, "pr_status", args) == first
      assert_received :conditional
    end
  end

  describe "without a GitHub connection" do
    test "a GitHub repo says to connect GitHub, with the link and the help workflow", %{
      scope: scope
    } do
      stub()

      assert {:error, msg} =
               Tools.run(scope, "pr_status", %{
                 "repo" => "example-org/example-repo",
                 "number" => 7
               })

      assert msg =~
               "`example-org/example-repo` is on GitHub, and your GitHub account isn't connected"

      assert msg =~ "http://localhost:4002/connections#connection-github"
      assert msg =~ "`help` workflow"
      assert github_requests() == []
    end

    test "joins and searches stay on Forgejo, without a note", %{scope: scope} do
      stub()
      md = run!(scope, "my_work", %{})
      assert md =~ "demo/app#42"
      refute md =~ "example-org"
      refute md =~ "GitHub"
      assert github_requests() == []
    end
  end

  describe "clearer errors for repos on the wrong host" do
    test "a Forgejo 404 or 400 for a repo says it isn't on Forgejo and how to reach GitHub", %{
      scope: scope
    } do
      for status <- [404, 400] do
        stub(%{
          "forgejo.test" => fn conn ->
            conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"message" => "nope"})
          end
        })

        assert {:error, msg} =
                 Tools.run(scope, "repo_search_prs", %{"repo" => "other-org/other-repo"})

        assert msg ==
                 "`other-org/other-repo` isn't on Forgejo, or you can't see it there. If it's " <>
                   "on GitHub, use `github:other-org/other-repo`, or ask the admin to add " <>
                   "`other-org` to GITHUB_OWNERS."

        refute msg =~ "this part is missing"
      end
    end

    test "a 4xx on a named resource no longer reads as an outage" do
      assert Upstreams.problem(:plane, {:status, 400}) =~ "Plane refused the request (HTTP 400)"
      assert Upstreams.problem(:plane, {:status, 422}) =~ "doesn't exist or isn't valid"

      assert Upstreams.problem(:releases, {:status, 503}) =~
               "answered HTTP 503; this part is missing"
    end
  end

  describe "joins" do
    setup :with_github

    test "task_status matches a Plane task to a GitHub PR, with its CI and reviews", %{
      scope: scope
    } do
      stub()
      md = run!(scope, "task_status", %{"id" => "DEMO-12"})

      assert md =~ "[demo/app#42](https://git.example.com/demo/app/pulls/42)"

      assert md =~
               "[example-org/example-repo#7](https://github.example/example-org/example-repo/pull/7) | open | ❌ failure | carla-gh: changes requested"

      assert md =~ "`9a8b7c6d5e` (example-org/example-repo#7)"
      refute md =~ "**Notes**"
    end

    test "my_work lists GitHub PRs from the configured owners", %{scope: scope} do
      stub()
      md = run!(scope, "my_work", %{})

      assert md =~ "| [example-org/example-repo#7]"
      assert md =~ "| [demo/app#42]"

      searches =
        for {_, "GET", "/search/issues", _} <- github_requests(), do: :search

      assert length(searches) == 2

      assert %{upstreams: upstreams} = hd(Audit.list(%{user_id: scope.user.id}))
      assert "github" in upstreams
    end

    test "a GitHub outage is a note; the rest still renders", %{scope: scope} do
      stub(%{"api.github.test" => {:status, 500}})

      for {tool, args} <- [{"my_work", %{}}, {"task_status", %{"id" => "DEMO-12"}}] do
        md = run!(scope, tool, args)
        assert md =~ "demo/app#42"
        assert md =~ "**Notes**"
        assert md =~ "GitHub answered HTTP 500; this part is missing."
      end
    end

    test "a rejected GitHub link is a note, not a failure", %{user: user} do
      Switchboard.Repo.update_all(
        from(c in Switchboard.Connections.Connection,
          where: c.user_id == ^user.id and c.system == "github"
        ),
        set: [status: "rejected"]
      )

      stub()
      md = run!(Scope.for_user(user), "my_work", %{})
      assert md =~ "demo/app#42"
      assert md =~ "GitHub rejected your key"
    end

    test "workflows prefetch GitHub PRs too", %{scope: scope} do
      stub()
      assert {:ok, text} = Workflows.run(scope, "next", %{})
      assert text =~ "example-org/example-repo#7"
      assert text =~ ~s(<untrusted source="forgejo github">)
    end
  end

  describe "argument aliases and errors" do
    test "an alias is renamed to the real argument and recorded in the audit", %{scope: scope} do
      stub()
      md = run!(scope, "plane_get_item", %{"identifier" => "DEMO-12"})
      assert md =~ "## DEMO-12: Export invoices as CSV"

      assert [%{args: %{"id" => "DEMO-12", "_aliases" => %{"identifier" => "id"}}} | _] =
               Audit.list(%{user_id: scope.user.id})

      assert run!(scope, "pr_status", %{"repository" => "demo/app", "pr" => 42}) =~
               "## demo/app#42"

      assert run!(scope, "ci_failure", %{"repo" => "demo/app", "number" => 42}) =~
               "CI failure: demo/app run #7"

      assert run!(scope, "task_status", %{"task" => "DEMO-12"}) =~ "## DEMO-12"
    end

    test "the real name wins; an alias next to it is unknown", %{scope: scope} do
      stub()

      assert {:error, "Unknown arguments: task. plane_get_item takes:" <> _} =
               Tools.run(scope, "plane_get_item", %{"id" => "DEMO-12", "task" => "DEMO-9"})
    end

    test "a missing argument lists what the tool takes and an example call", %{scope: scope} do
      assert {:error, msg} = Tools.run(scope, "plane_get_item", %{"ticket" => "DEMO-12"})

      assert msg ==
               """
               Missing arguments: id. Unknown arguments: ticket. plane_get_item takes:
               - `id` (required, string): Work item identifier, e.g. PROJ-123.
               Also accepted: `identifier`, `issue`, `issue_id`, `item`, `key`, `task`, `task_id`, `work_item` for `id`.
               Example: {"id":"DEMO-12"}\
               """

      assert {:error, msg} = Tools.run(scope, "pr_status", %{})
      assert msg =~ "Missing arguments: repo. pr_status takes:"
      assert msg =~ "- `repo` (required, string): Repository: owner/name"
      assert msg =~ "- `number` (optional, integer): Pull request number"
      assert msg =~ ~s(Example: {"number":42,"repo":"demo/app"})

      assert {:error, msg} =
               Tools.run(scope, "pr_status", %{"repo" => "demo/app", "number" => "x"})

      assert msg =~ "Invalid arguments: number (integer)."
    end
  end
end
