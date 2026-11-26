defmodule Switchboard.WatchesTest do
  # Watches against synthetic upstreams: creation, polling, the webhook path, expiry, limits,
  # notices (locale, once only) and ownership.
  use Switchboard.DataCase, async: true
  use Oban.Testing, repo: Switchboard.Repo

  import Switchboard.OAuthFixtures
  import Switchboard.UpstreamStubs, only: [stub: 0, stub: 1, link_all: 1]

  alias Switchboard.{Controls, Scope, Tools, Watches}
  alias Switchboard.Connections.Connection
  alias Switchboard.Watches.{CiPoll, Deliver, Hint, Sweep, TaskPoll, Watch}

  @sha "4f2c9e1a3b5d7f9e1a3b5d7f9e1a3b5d7f9e1a3b"

  setup do
    user =
      user_fixture(%{
        username: "ana",
        name: "Ana García",
        forgejo_id: 900_000 + System.unique_integer([:positive])
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

    ci = start_supervised!({Agent, fn -> %{visible: true, runs: [], next_id: 9000} end})
    admin = %{user_fixture() | admin: true}

    {:ok,
     user: user,
     scope: Scope.for_user(user, client_name: "test"),
     ci: ci,
     admin: Scope.for_user(admin)}
  end

  ## A small Forgejo: repo demo/app, PR 42 and branch main at @sha, runs from the agent.

  defp ci_stub(ci) do
    test = self()

    stub(%{
      "forgejo.test" => fn conn ->
        # The owner's Forgejo token can do anything: watches only ever read with it.
        if conn.method != "GET", do: raise("watch made a Forgejo #{conn.method}")

        send(
          test,
          {:forgejo, conn.method, conn.request_path,
           Plug.Conn.get_req_header(conn, "authorization")}
        )

        state = Agent.get(ci, & &1)
        params = URI.decode_query(conn.query_string)

        case conn.request_path do
          _ when not state.visible ->
            conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "not found"})

          "/api/v1/repos/demo/app" ->
            Req.Test.json(conn, %{"full_name" => "demo/app"})

          "/api/v1/repos/demo/app/pulls/42" ->
            Req.Test.json(conn, %{"number" => 42, "head" => %{"sha" => @sha}})

          "/api/v1/repos/demo/app/branches/main" ->
            Req.Test.json(conn, %{"name" => "main", "commit" => %{"id" => @sha}})

          "/api/v1/repos/demo/app/actions/runs" ->
            runs =
              cond do
                params["run_number"] ->
                  Enum.filter(
                    state.runs,
                    &(to_string(&1["index_in_repo"]) == params["run_number"])
                  )

                params["head_sha"] ->
                  Enum.filter(state.runs, &(&1["commit_sha"] == params["head_sha"]))

                true ->
                  Enum.take(state.runs, 1)
              end

            Req.Test.json(conn, %{"workflow_runs" => runs, "total_count" => length(runs)})

          "/api/v1/repos/demo/app/actions/runs/" <> _ ->
            Req.Test.json(conn, [%{"id" => 555, "name" => "test", "status" => "failure"}])

          "/api/v1/repos/demo/app/actions/jobs/555/logs" ->
            conn
            |> Plug.Conn.put_resp_content_type("text/plain")
            |> Plug.Conn.send_resp(200, Switchboard.UpstreamStubs.ci_log())
        end
      end
    })
  end

  # Newest first, like Forgejo.
  defp add_run(ci, status, sha \\ @sha) do
    Agent.get_and_update(ci, fn s ->
      id = s.next_id + 1

      run = %{
        "id" => id,
        "index_in_repo" => id - 9000,
        "status" => status,
        "commit_sha" => sha,
        "workflow_id" => "ci.yml",
        "html_url" => "https://git.example.com/demo/app/actions/runs/#{id - 9000}"
      }

      {id, %{s | runs: [run | s.runs], next_id: id}}
    end)
  end

  defp set_runs(ci, status),
    do:
      Agent.update(ci, fn s -> %{s | runs: Enum.map(s.runs, &Map.put(&1, "status", status))} end)

  defp the_watch(user),
    do: Repo.one!(from w in Watch, where: w.user_id == ^user.id) |> Repo.preload(:user)

  defp poll(watch), do: perform_job(CiPoll, %{watch_id: watch.id})

  defp deliver_all do
    for job <- all_enqueued(worker: Deliver) do
      perform_job(Deliver, job.args)
    end
  end

  defp dms do
    receive_all([])
    |> Enum.filter(
      &match?({:upstream_write, "chat.test", "POST", "/api/v1/chat.postMessage", _, _}, &1)
    )
    |> Enum.map(fn {_, _, _, _, creds, body} ->
      {creds["x-auth-token"], body["roomId"], body["text"]}
    end)
  end

  defp receive_all(acc) do
    receive do
      msg -> receive_all([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "watch_ci" do
    test "creates a watch after checking the repo with the person's own token, polls, and DMs the failure once",
         %{scope: scope, user: user, ci: ci} do
      ci_stub(ci)
      add_run(ci, "running")

      assert {:ok, msg} = Tools.run(scope, "watch_ci", %{"repo" => "demo/app", "pr" => 42})
      assert msg =~ "Watching demo/app#42"
      assert msg =~ "(as @ana)"
      assert_received {:forgejo, "GET", "/api/v1/repos/demo/app", ["Bearer forgejo-token-" <> _]}

      watch = the_watch(user)
      assert watch.status == "active"
      assert_enqueued(worker: CiPoll, args: %{watch_id: watch.id})

      # Still running: nothing to say, the next check is scheduled later.
      assert :ok = poll(watch)
      assert the_watch(user).checks == 1
      refute_enqueued(worker: Deliver)

      set_runs(ci, "failure")
      assert :ok = poll(the_watch(user))
      watch = the_watch(user)
      assert (watch.status == "fired" and watch.end_reason == "notified") && watch.notified_at
      assert watch.last_state["result"] == "failure"

      receive_all([])
      deliver_all()
      assert [{"bot-token", "dm-ana", text}] = dms()
      assert text =~ "❌ CI falló: demo/app#42"
      assert text =~ ~s(Job test, paso "Run tests") or text =~ ~s(Trabajo test, paso "Run tests")
      assert text =~ "https://git.example.com/demo/app/actions/runs/1"
      assert text =~ "Aviso automático de Switchboard"
      assert text =~ "/watches"

      # Another check, a retried job or a second node: no second notice.
      assert :ok = poll(the_watch(user))
      assert :already = Watches.notify(the_watch(user), %{})
      deliver_all()
      assert dms() == []
      assert the_watch(user).deliveries == %{"result" => "sent"}
    end

    test "refuses a repo the person can't see, and answers a run that already finished", %{
      scope: scope,
      ci: ci
    } do
      ci_stub(ci)
      add_run(ci, "success")

      assert {:error, msg} = Tools.run(scope, "watch_ci", %{"repo" => "demo/app", "pr" => 42})
      assert msg =~ "already finished: success"

      Agent.update(ci, &%{&1 | visible: false})

      assert {:error, msg} =
               Tools.run(scope, "watch_ci", %{"repo" => "demo/app", "branch" => "main"})

      assert msg =~ "can't see it"
      assert Repo.aggregate(Watch, :count) == 0

      assert {:error, msg} = Tools.run(scope, "watch_ci", %{"repo" => "demo/app"})
      assert msg =~ "exactly one"

      assert {:error, _} =
               Tools.run(scope, "watch_ci", %{
                 "repo" => "demo/app",
                 "run" => 1,
                 "next_run" => true
               })
    end

    test "next_run waits for a run newer than the one at creation; only_on_failure stays quiet on success",
         %{scope: scope, user: user, ci: ci} do
      ci_stub(ci)
      add_run(ci, "success")

      assert {:ok, _} =
               Tools.run(scope, "watch_ci", %{
                 "repo" => "demo/app",
                 "branch" => "main",
                 "next_run" => true,
                 "only_on_failure" => true
               })

      watch = the_watch(user)
      assert :ok = poll(watch)
      assert the_watch(user).status == "active"

      add_run(ci, "success")
      assert :ok = poll(the_watch(user))
      watch = the_watch(user)
      assert watch.status == "fired" and watch.end_reason == "succeeded_quietly"
      refute_enqueued(worker: Deliver)
    end

    test "a lost repo ends the watch with one final DM and nothing about the repo", %{
      scope: scope,
      user: user,
      ci: ci
    } do
      ci_stub(ci)
      add_run(ci, "running")
      {:ok, _} = Tools.run(scope, "watch_ci", %{"repo" => "demo/app", "pr" => 42})

      Agent.update(ci, &%{&1 | visible: false})
      assert :ok = poll(the_watch(user))
      watch = the_watch(user)
      assert watch.status == "expired" and watch.end_reason == "access_lost"

      receive_all([])
      deliver_all()
      assert [{"bot-token", "dm-ana", text}] = dms()
      assert text =~ "ya no tienes acceso"
      refute text =~ "runs/"
    end

    test "a removed Forgejo connection ends it too", %{scope: scope, user: user, ci: ci} do
      ci_stub(ci)
      add_run(ci, "running")
      {:ok, _} = Tools.run(scope, "watch_ci", %{"repo" => "demo/app", "pr" => 42})

      Repo.delete_all(
        from c in Connection, where: c.user_id == ^user.id and c.system == "forgejo"
      )

      assert :ok = poll(the_watch(user))
      assert the_watch(user).end_reason == "connection_missing"
    end
  end

  describe "the Forgejo webhook" do
    import Plug.Test

    defp hook(body, signature, opts \\ []) do
      conn(:post, "/hooks/forgejo", body)
      |> Plug.Conn.put_req_header("content-type", Keyword.get(opts, :type, "application/json"))
      |> Plug.Conn.put_req_header(
        "x-forgejo-event",
        Keyword.get(opts, :event, "action_run_success")
      )
      |> then(
        &if signature,
          do: Plug.Conn.put_req_header(&1, "x-forgejo-signature", signature),
          else: &1
      )
      |> SwitchboardWeb.Endpoint.call([])
    end

    defp sign(body, secret \\ "hook-secret"),
      do: :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)

    @payload Jason.encode!(%{
               "action" => "success",
               "run" => %{
                 "id" => 9001,
                 "status" => "success",
                 "repository" => %{"full_name" => "Demo/App"}
               }
             })

    test "a good signature queues a hint; bad, missing or unconfigured are refused" do
      assert hook(@payload, sign(@payload)).status == 202
      assert_enqueued(worker: Hint, args: %{repo: "demo/app"})

      assert hook(@payload, sign(@payload, "wrong")).status == 401
      assert hook(@payload, nil).status == 401
      assert hook(@payload <> " ", sign(@payload)).status == 401

      assert hook(@payload, sign(@payload), type: "application/x-www-form-urlencoded").status ==
               415

      big = String.duplicate("a", 1_100_000)
      assert hook(big, sign(big)).status == 413

      # Other events are accepted and ignored.
      Repo.delete_all(Oban.Job)
      assert hook(@payload, sign(@payload), event: "push").status == 202
      refute_enqueued(worker: Hint)

      secret = Application.get_env(:switchboard, :forgejo_webhook_secret)
      Application.delete_env(:switchboard, :forgejo_webhook_secret)
      on_exit(fn -> Application.put_env(:switchboard, :forgejo_webhook_secret, secret) end)
      assert hook(@payload, sign(@payload)).status == 503
      Application.put_env(:switchboard, :forgejo_webhook_secret, secret)
    end

    test "a hint only moves the check earlier; the check re-reads Forgejo with the owner's token",
         %{scope: scope, user: user, ci: ci} do
      ci_stub(ci)
      add_run(ci, "running")
      {:ok, _} = Tools.run(scope, "watch_ci", %{"repo" => "demo/app", "pr" => 42})
      watch = the_watch(user)
      # Pretend the creation check was a while ago.
      Repo.update_all(from(w in Watch, where: w.id == ^watch.id),
        set: [last_checked_at: ~U[2026-01-01 00:00:00Z]]
      )

      [job] = all_enqueued(worker: CiPoll)
      assert DateTime.diff(job.scheduled_at, DateTime.utc_now()) > 30

      # The webhook says "success", Forgejo (asked again) says it's still running: no notice.
      assert :ok = perform_job(Hint, %{repo: "demo/app"})
      [job] = all_enqueued(worker: CiPoll)
      assert DateTime.diff(job.scheduled_at, DateTime.utc_now()) <= 1

      receive_all([])
      assert :ok = poll(the_watch(user))

      assert_received {:forgejo, "GET", "/api/v1/repos/demo/app/actions/runs",
                       ["Bearer forgejo-token-" <> _]}

      assert the_watch(user).status == "active"
      refute_enqueued(worker: Deliver)

      # Hints for repos nobody watches do nothing.
      assert :ok = perform_job(Hint, %{repo: "other/repo"})
    end
  end

  describe "watch_task" do
    defp plane_state(name, group, id) do
      stub(%{
        "plane.test" => fn conn ->
          Req.Test.json(conn, %{
            "id" => "i-12",
            "project" => "p-demo",
            "name" => "Export invoices as CSV",
            "state" => %{"id" => id, "name" => name, "group" => group}
          })
        end
      })
    end

    test "DMs when the state changes, through the person's own Plane key, in English for English profiles",
         %{user: user} do
      user = user |> Ecto.Changeset.change(locale: "en") |> Repo.update!()
      scope = Scope.for_user(user)
      plane_state("In Progress", "started", "s-prog")

      assert {:ok, msg} = Tools.run(scope, "watch_task", %{"id" => "demo-12"})
      assert msg =~ "Watching DEMO-12"

      assert :ok = perform_job(TaskPoll, %{user_id: user.id})
      assert the_watch(user).status == "active"

      Switchboard.Cache.delete_match({:plane_get, :_, :_, :_})
      plane_state("In Review", "started", "s-review")
      assert :ok = perform_job(TaskPoll, %{user_id: user.id})
      assert the_watch(user).status == "fired"

      receive_all([])
      deliver_all()
      assert [{"bot-token", "dm-ana", text}] = dms()
      assert text =~ "DEMO-12 moved to In Review (was In Progress)."
      assert text =~ "Automatic notice from Switchboard. Replies here aren't read."
    end

    test "until done ignores other moves; the sweep queues one Plane pass per person every 5 minutes",
         %{scope: scope, user: user} do
      plane_state("Todo", "unstarted", "s-todo")
      {:ok, _} = Tools.run(scope, "watch_task", %{"id" => "DEMO-12", "until" => "done"})

      Switchboard.Cache.delete_match({:plane_get, :_, :_, :_})
      plane_state("In Progress", "started", "s-prog")
      assert :ok = perform_job(TaskPoll, %{user_id: user.id})
      assert the_watch(user).status == "active"

      # Recently checked: the sweep doesn't queue another pass yet.
      assert :ok = perform_job(Sweep, %{})
      refute_enqueued(worker: TaskPoll)

      Repo.update_all(Watch,
        set: [last_checked_at: DateTime.add(DateTime.utc_now(:second), -600)]
      )

      assert :ok = perform_job(Sweep, %{})
      assert_enqueued(worker: TaskPoll, args: %{user_id: user.id})

      Switchboard.Cache.delete_match({:plane_get, :_, :_, :_})
      plane_state("Done", "completed", "s-done")
      assert :ok = perform_job(TaskPoll, %{user_id: user.id})
      assert the_watch(user).last_state["previous_state"] == "In Progress"
    end

    test "until released fires when a new release ships it (the shared feed)", %{
      scope: scope,
      user: user
    } do
      # At creation the feed has no release with DEMO-12.
      stub(%{"releases.test" => fn conn -> Req.Test.json(conn, %{"releases" => []}) end})
      {:ok, _} = Tools.run(scope, "watch_task", %{"id" => "DEMO-12", "until" => "released"})

      stub()
      assert :ok = perform_job(Sweep, %{})
      watch = the_watch(user)
      assert watch.status == "fired"
      assert watch.last_state["release"] == "release-2026.11.26.1"
      # until: released never reads Plane after creation.
      refute_enqueued(worker: TaskPoll)
    end
  end

  describe "watch_release" do
    test "DMs the next release with its highlights, then the health after the window",
         %{scope: scope, user: user} do
      [ok, deploying] = Switchboard.UpstreamStubs.sample_releases()
      # At creation: only an older release is finished.
      stub(%{
        "releases.test" => fn conn ->
          Req.Test.json(conn, %{
            "releases" => [deploying, %{ok | "name" => "old", "status" => "success"}]
          })
        end
      })

      assert {:ok, msg} = Tools.run(scope, "watch_release", %{"repo" => "app", "health" => true})
      assert msg =~ "again with its health"
      assert {:error, msg} = Tools.run(scope, "watch_release", %{"repo" => "nope"})
      assert msg =~ "No release of nope"

      # The next release succeeded and is still in its 24 h window.
      stub(%{
        "releases.test" => fn conn -> Req.Test.json(conn, %{"releases" => [ok, deploying]}) end
      })

      assert :ok = perform_job(Sweep, %{})
      watch = the_watch(user)

      assert watch.status == "active" && watch.notified_at &&
               watch.last_state["phase"] == "health"

      receive_all([])
      deliver_all()
      assert [{_, _, text}] = dms()

      assert text =~ "🚀 Versión app release-2026.11.26.1: success" or
               text =~ "release-2026.11.26.1"

      assert text =~ "> Invoices can be exported as CSV (DEMO-12)"

      # Still watching: no health notice yet.
      assert :ok = perform_job(Sweep, %{})
      assert the_watch(user).health_notified_at == nil

      done = %{ok | "watching" => false, "health" => "red"}

      stub(%{
        "releases.test" => fn conn -> Req.Test.json(conn, %{"releases" => [done, deploying]}) end
      })

      assert :ok = perform_job(Sweep, %{})
      watch = the_watch(user)
      assert watch.status == "fired" && watch.health_notified_at

      receive_all([])
      deliver_all()
      assert [{_, _, text}] = dms()
      assert text =~ "🔴"
      assert text =~ "KeyError: 'currency'"

      assert :ok = perform_job(Sweep, %{})
      deliver_all()
      assert dms() == []
    end
  end

  describe "expiry, limits, pause and ownership" do
    test "a timed-out watch expires without a DM but still shows as expired",
         %{scope: scope, user: user, ci: ci} do
      ci_stub(ci)
      add_run(ci, "running")
      {:ok, _} = Tools.run(scope, "watch_ci", %{"repo" => "demo/app", "pr" => 42, "hours" => 1})

      assert Watches.expire_due(DateTime.add(DateTime.utc_now(), 2 * 3600)) == 1
      watch = the_watch(user)
      assert watch.status == "expired" and watch.end_reason == "timed_out"
      assert watch.notified_at == nil
      assert Watches.expire_due(DateTime.add(DateTime.utc_now(), 3 * 3600)) == 0
      refute_enqueued(worker: Deliver)

      assert {:ok, md} = Tools.run(scope, "list_watches", %{})
      assert md =~ "demo/app#42" and md =~ "| expired |"

      # The check job also notices the deadline, without a DM.
      {:ok, _} = Tools.run(scope, "watch_ci", %{"repo" => "demo/app", "branch" => "main"})

      branch =
        Repo.one!(from w in Watch, where: w.status == "active", preload: :user)

      Repo.update_all(from(w in Watch, where: w.id == ^branch.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(:second), -1)]
      )

      assert :ok = poll(Repo.preload(Repo.get!(Watch, branch.id), :user))
      assert Repo.get!(Watch, branch.id).end_reason == "timed_out"
      refute_enqueued(worker: Deliver)
    end

    test "per-person limit and duplicates", %{scope: scope, user: user, ci: ci} do
      ci_stub(ci)
      add_run(ci, "running")

      for n <- 1..20 do
        Repo.insert!(%Watch{
          user_id: user.id,
          kind: "task",
          target: %{"id" => "DEMO-#{n}"},
          subject: "DEMO-#{n}",
          expires_at: DateTime.add(DateTime.utc_now(:second), 3600)
        })
      end

      assert {:error, msg} = Tools.run(scope, "watch_ci", %{"repo" => "demo/app", "pr" => 42})
      assert msg =~ "20 active watches, the limit"

      Repo.delete_all(Watch)
      assert {:ok, _} = Tools.run(scope, "watch_ci", %{"repo" => "demo/app", "pr" => 42})
      assert {:error, msg} = Tools.run(scope, "watch_ci", %{"repo" => "demo/app", "pr" => 42})
      assert msg =~ "already watch demo/app#42"

      # Other people have their own limits.
      other = user_fixture()
      assert Watches.active_count(other) == 0
    end

    test "the admin pause stops new watches, checks and notices", %{
      scope: scope,
      user: user,
      admin: admin,
      ci: ci
    } do
      ci_stub(ci)
      add_run(ci, "running")
      {:ok, _} = Tools.run(scope, "watch_ci", %{"repo" => "demo/app", "pr" => 42})
      watch = the_watch(user)
      {:ok, _} = Controls.update_global(admin, %{watches_paused: true})

      assert {:error, msg} =
               Tools.run(scope, "watch_ci", %{"repo" => "demo/app", "branch" => "main"})

      assert msg =~ "paused"

      set_runs(ci, "failure")
      receive_all([])
      assert :ok = poll(watch)
      refute_received {:forgejo, _, _, _}
      assert the_watch(user).status == "active"

      Watches.notify(watch, %{"result" => "failure", "runs" => []})
      [job] = all_enqueued(worker: Deliver)
      assert {:snooze, _} = perform_job(Deliver, job.args)
      assert dms() == []
    end

    test "list_watches and cancel_watch see only the caller's watches", %{
      scope: scope,
      user: user,
      ci: ci
    } do
      ci_stub(ci)
      add_run(ci, "running")
      {:ok, _} = Tools.run(scope, "watch_ci", %{"repo" => "demo/app", "pr" => 42})
      watch = the_watch(user)

      bea = user_fixture(%{username: "bea"})
      bea_scope = Scope.for_user(bea)
      assert {:ok, msg} = Tools.run(bea_scope, "list_watches", %{})
      assert msg =~ "no watches"
      assert {:error, msg} = Tools.run(bea_scope, "cancel_watch", %{"id" => watch.id})
      assert msg =~ "no watch with id"
      assert the_watch(user).status == "active"

      assert {:ok, msg} = Tools.run(scope, "list_watches", %{})
      assert msg =~ watch.id
      assert msg =~ "demo/app#42"

      assert {:ok, msg} = Tools.run(scope, "cancel_watch", %{"id" => watch.id})
      assert msg =~ "Cancelled"
      assert the_watch(user).status == "cancelled"
      assert :ok = poll(the_watch(user))
      refute_enqueued(worker: Deliver)
      assert {:error, _} = Tools.run(scope, "cancel_watch", %{"id" => "not-a-uuid"})
    end

    test "watch notices per person are capped per hour (they wait, not drop)", %{user: user} do
      watch =
        Repo.insert!(%Watch{
          user_id: user.id,
          kind: "task",
          target: %{"id" => "DEMO-1"},
          subject: "DEMO-1",
          expires_at: DateTime.add(DateTime.utc_now(:second), 3600)
        })

      :notified = Watches.notify(watch, %{"event" => "state", "state" => "Done"})

      for _ <- 1..30,
          do: Switchboard.RateLimit.take({user.id, :watch_notices}, 30, :timer.hours(1))

      [job] = all_enqueued(worker: Deliver)
      stub()
      assert {:snooze, _} = perform_job(Deliver, job.args)
      assert dms() == []
    end

    test "the sweep re-creates a missing check job (recovery after a restart)", %{
      scope: scope,
      user: user,
      ci: ci
    } do
      ci_stub(ci)
      add_run(ci, "running")
      {:ok, _} = Tools.run(scope, "watch_ci", %{"repo" => "demo/app", "pr" => 42})
      Repo.delete_all(Oban.Job)
      assert :ok = perform_job(Sweep, %{})
      assert_enqueued(worker: CiPoll, args: %{watch_id: the_watch(user).id})
    end
  end
end
