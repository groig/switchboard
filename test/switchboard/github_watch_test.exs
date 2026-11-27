defmodule Switchboard.GitHubWatchTest do
  # watch_ci on a GitHub pull request: polled (GitHub has no webhook here), read with the owner's
  # own GitHub token, GET only, one notice.
  use Switchboard.DataCase, async: true
  use Oban.Testing, repo: Switchboard.Repo

  import Switchboard.OAuthFixtures
  import Switchboard.UpstreamStubs, only: [stub: 1, link_all: 1, link_github: 1, gh_run: 2]

  alias Switchboard.{Scope, Tools}
  alias Switchboard.Connections.Connection
  alias Switchboard.Watches.{CiPoll, Deliver, Hint, Watch}

  setup do
    user =
      user_fixture(%{username: "ana", forgejo_id: 900_000 + System.unique_integer([:positive])})
      |> link_all()
      |> link_github()

    Repo.insert!(%Connection{
      user_id: user.id,
      system: "rocketchat",
      secret: %{"token" => "rc-personal-#{user.id}", "user_id" => "rc-uid-ana"},
      status: "ok",
      identity: %{"username" => "ana"},
      identity_matches: true
    })

    run = start_supervised!({Agent, fn -> {"in_progress", nil} end})
    test = self()

    stub(%{
      "api.github.test" => fn conn ->
        if conn.method != "GET", do: send(test, {:github_write, conn.method, conn.request_path})

        {status, conclusion} = Agent.get(run, & &1)

        case conn.request_path do
          "/repos/example-org/example-repo/actions/runs" ->
            Req.Test.json(conn, %{"workflow_runs" => [gh_run(status, conclusion)]})

          _ ->
            Switchboard.UpstreamStubs.github(conn)
        end
      end
    })

    {:ok, user: user, scope: Scope.for_user(user, client_name: "test"), run: run}
  end

  defp the_watch(user),
    do: Repo.one!(from w in Watch, where: w.user_id == ^user.id) |> Repo.preload(:user)

  defp poll(watch), do: perform_job(CiPoll, %{watch_id: watch.id})

  defp dms do
    for job <- all_enqueued(worker: Deliver), do: perform_job(Deliver, job.args)

    collect([])
    |> Enum.filter(
      &match?({:upstream_write, "chat.test", "POST", "/api/v1/chat.postMessage", _, _}, &1)
    )
    |> Enum.map(fn {_, _, _, _, _creds, body} -> body["text"] end)
  end

  defp collect(acc) do
    receive do
      msg -> collect([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "watches a GitHub PR's runs and DMs the failed job and step once", %{
    scope: scope,
    user: user,
    run: run
  } do
    assert {:ok, msg} =
             Tools.run(scope, "watch_ci", %{"repo" => "example-org/example-repo", "pr" => 7})

    assert msg =~ "Watching github:example-org/example-repo#7"

    watch = the_watch(user)
    assert watch.target == %{"repo" => "github:example-org/example-repo", "pr" => 7}
    assert watch.subject == "github:example-org/example-repo"

    assert :ok = poll(watch)
    assert the_watch(user).status == "active"
    refute_enqueued(worker: Deliver)

    Agent.update(run, fn _ -> {"completed", "failure"} end)
    assert :ok = poll(the_watch(user))
    assert %{status: "fired", last_state: %{"result" => "failure"}} = the_watch(user)

    collect([])
    assert [text] = dms()
    assert text =~ "github:example-org/example-repo#7"
    assert text =~ ~s("Run tests")
    assert text =~ "https://github.example/example-org/example-repo/actions/runs/4242"

    # Only reads, and the failed step came from the jobs API (no log download).
    refute_received {:github_write, _, _}
    refute_received {:github, "logs.github.test", _, _, _}
  end

  test "a run that already finished is answered, not watched", %{scope: scope, run: run} do
    Agent.update(run, fn _ -> {"completed", "success"} end)

    assert {:error, msg} =
             Tools.run(scope, "watch_ci", %{
               "repo" => "http://github.test/example-org/example-repo/pull/7"
             })

    assert msg =~ "CI for this already finished: success"
  end

  test "a Forgejo webhook for the same name doesn't touch GitHub watches", %{
    scope: scope,
    user: user
  } do
    assert {:ok, _} =
             Tools.run(scope, "watch_ci", %{"repo" => "example-org/example-repo", "pr" => 7})

    watch = the_watch(user)
    assert :ok = perform_job(Hint, %{"repo" => "example-org/example-repo"})
    # The first check stays a minute out: the hint matched nothing (it would move it to now).
    assert [job] = all_enqueued(worker: CiPoll, args: %{watch_id: watch.id})
    assert DateTime.diff(job.scheduled_at, DateTime.utc_now()) > 30
  end
end
