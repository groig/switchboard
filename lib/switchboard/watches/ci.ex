defmodule Switchboard.Watches.CI do
  @moduledoc """
  What a CI watch sees, through `Switchboard.Forgejo` or `Switchboard.GitHub` (both GET only)
  with the owner's own token. A GitHub target's repo is stored as `github:owner/name`; a bare
  `owner/name` is Forgejo (watches from before GitHub, and Forgejo ones), whatever
  `GITHUB_OWNERS` says later. GitHub runs are polled; only Forgejo has the webhook hint.

  A watch follows a pull request (its head commit), a branch (its head commit) or one Actions run
  (by number). For a commit, every run of every workflow for it counts: the watch is done when
  there is at least one run and all are done (`success`, `failure`, `cancelled`, `skipped`); the
  result is `failure` if any failed. With `next_run`, only runs newer than the newest run when the
  watch was created count (the run that a push is about to start).
  """
  alias Switchboard.{Forgejo, GitHub, Repos}
  alias Switchboard.Repos.Ref

  @done ~w(success failure cancelled skipped)
  @max_failed_runs 2
  @max_failed_jobs 2

  @doc """
  The creation check: the repo is visible to the person, the target exists. Returns
  `{:ok, target, state}` or `{:error, reason}`.
  """
  def prepare(scope, %Ref{} = ref, kind, value, next_run?) do
    target = %{"repo" => Ref.stored(ref), kind => value}
    client = Repos.client(ref)

    with {:ok, _repo} <- client.repo(scope, ref.owner, ref.name) |> repo_level(),
         {:ok, _} <- exists(client, scope, ref, kind, value),
         {:ok, baseline} <- baseline(client, scope, ref, next_run?) do
      {:ok, target, %{"baseline" => baseline, "result" => nil}}
    end
  end

  # The repository itself missing is reported as such (`{:repo, reason}`), not as a missing PR.
  defp repo_level({:error, reason}), do: {:error, {:repo, reason}}
  defp repo_level(ok), do: ok

  defp exists(client, scope, ref, "pr", n), do: client.pull(scope, ref.owner, ref.name, n)
  defp exists(client, scope, ref, "branch", b), do: client.branch(scope, ref.owner, ref.name, b)

  defp exists(client, scope, ref, "run", n) do
    case client.runs(scope, ref.owner, ref.name, run_number: n) do
      {:ok, %{"workflow_runs" => [_ | _]}} -> {:ok, :run}
      {:ok, _} -> {:error, :not_found}
      error -> error
    end
  end

  defp baseline(_client, _scope, _ref, false), do: {:ok, nil}

  defp baseline(client, scope, ref, true) do
    case client.runs(scope, ref.owner, ref.name, limit: 1) do
      {:ok, %{"workflow_runs" => [run | _]}} -> {:ok, run["id"]}
      {:ok, _} -> {:ok, 0}
      error -> error
    end
  end

  @doc """
  Checks a watch. `{:pending, state}`, `{:done, state}` (with `"result"` and `"runs"`),
  `{:stop, reason}` when it can't work any more, or `{:retry, reason}` for a passing problem.
  """
  def check(scope, %{target: target} = watch) do
    case Repos.resolve(target["repo"], default: :forgejo) do
      {:ok, ref} -> check(scope, ref, watch)
      # A GitHub watch after an admin switched GitHub off.
      {:error, _} -> {:stop, "connection_missing"}
    end
  end

  defp check(scope, ref, %{target: target, last_state: last}) do
    client = Repos.client(ref)
    {owner, name} = {ref.owner, ref.name}

    with {:ok, runs} <- runs_for(client, scope, owner, name, target, last["baseline"]) do
      cond do
        runs == [] ->
          {:pending, Map.merge(last, %{"seen" => "waiting"})}

        Enum.all?(runs, &(&1["status"] in @done)) ->
          {:done, Map.merge(last, done_state(client, scope, owner, name, runs))}

        true ->
          {:pending,
           Map.merge(last, %{"seen" => Enum.map(runs, & &1["status"]) |> Enum.join(",")})}
      end
    end
    |> classify()
  end

  defp runs_for(client, scope, owner, name, %{"run" => n}, _baseline) do
    with {:ok, body} <- client.runs(scope, owner, name, run_number: n) do
      case body["workflow_runs"] do
        [_ | _] = runs -> {:ok, Enum.take(runs, 1)}
        _ -> {:error, :not_found}
      end
    end
  end

  defp runs_for(client, scope, owner, name, target, baseline) do
    with {:ok, sha} <- head_sha(client, scope, owner, name, target),
         {:ok, body} <- client.runs(scope, owner, name, head_sha: sha, limit: 20) do
      runs =
        (body["workflow_runs"] || [])
        |> Enum.filter(&(is_nil(baseline) or (&1["id"] || 0) > baseline))

      {:ok, runs}
    end
  end

  defp head_sha(client, scope, owner, name, %{"pr" => n}) do
    with {:ok, pr} <- client.pull(scope, owner, name, n),
         sha when is_binary(sha) <- get_in(pr, ["head", "sha"]) || {:error, :not_found},
         do: {:ok, sha}
  end

  defp head_sha(client, scope, owner, name, %{"branch" => b}) do
    with {:ok, branch} <- client.branch(scope, owner, name, b),
         sha when is_binary(sha) <- get_in(branch, ["commit", "id"]) || {:error, :not_found},
         do: {:ok, sha}
  end

  defp done_state(client, scope, owner, name, runs) do
    statuses = Enum.map(runs, & &1["status"])

    result =
      cond do
        "failure" in statuses -> "failure"
        "cancelled" in statuses -> "cancelled"
        true -> "success"
      end

    # Failed runs first, so the notice's link points at one.
    {failed, others} = Enum.split_with(runs, &(&1["status"] == "failure"))

    detail =
      failed
      |> Enum.take(@max_failed_runs)
      |> Enum.map(&run_summary(&1, failed_jobs(client, scope, owner, name, &1)))

    rest = Enum.map(others, &run_summary(&1, []))

    %{"result" => result, "runs" => detail ++ rest, "sha" => List.first(runs)["commit_sha"]}
  end

  defp run_summary(run, failed) do
    %{
      "number" => run["index_in_repo"] || run["id"],
      "workflow" => run["workflow_id"],
      "status" => run["status"],
      "url" => run["html_url"],
      "failed" => failed
    }
  end

  # The failed job and step, parsed like ci_failure does (the step name only, no log text).
  defp failed_jobs(client, scope, owner, name, run) do
    case client.jobs(scope, owner, name, run["id"]) do
      {:ok, jobs} when is_list(jobs) ->
        jobs
        |> Enum.filter(&(&1["status"] == "failure"))
        |> Enum.take(@max_failed_jobs)
        |> Enum.map(fn job ->
          step =
            job["failed_step"] ||
              case client.job_log(scope, owner, name, job["id"]) do
                {:ok, log} when is_binary(log) -> tail(client, log).step
                _ -> nil
              end

          %{"job" => job["name"], "step" => step}
        end)

      _ ->
        []
    end
  end

  defp tail(GitHub, log), do: GitHub.failure_tail(log)
  defp tail(_client, log), do: Forgejo.failure_tail(log)

  defp classify({:pending, _} = r), do: r
  defp classify({:done, _} = r), do: r
  defp classify({:error, reason}), do: problem(reason)

  @doc "Maps an upstream reason to `{:stop, end_reason}` or `{:retry, reason}`."
  def problem(:not_connected), do: {:stop, "connection_missing"}
  def problem(:rejected), do: {:stop, "connection_rejected"}
  def problem(:unauthorized), do: {:stop, "connection_rejected"}
  def problem(:not_found), do: {:stop, "access_lost"}
  def problem(:forbidden), do: {:stop, "access_lost"}
  def problem({:sso, _url}), do: {:stop, "access_lost"}
  def problem(reason), do: {:retry, reason}
end
