defmodule Switchboard.Tools.WatchCi do
  @moduledoc "Watch a pull request's, branch's or Actions run's CI; DM the result when it finishes."
  use Switchboard.Tools.Support

  alias Switchboard.Repos
  alias Switchboard.Repos.Ref
  alias Switchboard.Tools.WatchSupport
  alias Switchboard.Watches.CI

  @impl true
  def name, do: "watch_ci"
  @impl true
  def title, do: "Watch CI"
  @impl true
  def description,
    do:
      "Use when the user wants to be told when CI finishes (\"DM me when CI is done\"). " <>
        "Watches a pull request, branch or Actions run on Forgejo or GitHub and sends the user " <>
        "(only them) a " <>
        "Rocket.Chat DM with the result, the link and the failed job and step. Use next_run " <>
        "right after a push. It only notifies the user who asked, so their request is the " <>
        "confirmation."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "repo" => %{"type" => "string", "description" => Repos.schema_description()},
        "pr" => %{"type" => "integer", "description" => "Pull request number."},
        "branch" => %{"type" => "string", "description" => "Branch name."},
        "run" => %{
          "type" => "integer",
          "description" => "Actions run number as in the run URL (the run id on GitHub)."
        },
        "only_on_failure" => %{
          "type" => "boolean",
          "description" => "DM only if it fails (default false)."
        },
        "next_run" => %{
          "type" => "boolean",
          "description" =>
            "For a pr or branch: wait for the next run instead of the current one (default false)."
        },
        "hours" => WatchSupport.hours_schema()
      },
      "required" => ["repo"]
    }
  end

  @impl true
  def annotations,
    do: %{read_only: false, destructive: false, idempotent: false, open_world: true}

  @impl true
  def connections, do: [:forgejo, :github]

  @impl true
  def aliases,
    do: %{
      "repository" => "repo",
      "number" => "pr",
      "pr_number" => "pr",
      "index" => "pr",
      "pull" => "pr",
      "pull_request" => "pr",
      "run_id" => "run",
      "run_number" => "run"
    }

  @impl true
  def example do
    %{
      args: %{"repo" => "demo/app", "pr" => 42, "next_run" => true},
      output:
        "Watching demo/app#42: Switchboard will DM you in Rocket.Chat (as @ana) when the next " <>
          "CI run finishes. Expires 2026-11-27 10:00 (Europe/Madrid). Watch id: `5b1c…` " <>
          "(list_watches, cancel_watch, or https://switchboard.example.com/watches)."
    }
  end

  @impl true
  def call(scope, %{"repo" => repo} = args) do
    next_run? = args["next_run"] == true

    with {:ok, ref} <- Repos.resolve(repo),
         args = from_url(args, ref),
         {:ok, kind, value} <- target(args, next_run?),
         {:ok, hours} <- WatchSupport.hours(args),
         {:ok, username} <- WatchSupport.recipient(scope),
         {:ok, target, state} <-
           CI.prepare(scope, ref, kind, value, next_run?) |> prepare_error(scope, ref),
         :ok <- not_done_yet(scope, target, state, next_run?) do
      WatchSupport.create(
        scope,
        %{
          kind: "ci",
          target: target,
          subject: String.downcase(Ref.stored(ref)),
          options: %{
            "only_on_failure" => args["only_on_failure"] == true,
            "next_run" => next_run?
          },
          hours: hours,
          state: state
        },
        username,
        if(next_run?, do: "when the next CI run finishes", else: "when CI finishes")
        |> Kernel.<>(if(args["only_on_failure"] == true, do: ", only if it fails", else: ""))
      )
    end
  end

  # A pull request or run URL as repo stands for the pr / run argument.
  defp from_url(args, %Ref{pr: pr, run: run}) do
    cond do
      Enum.any?(~w(pr branch run), &Map.has_key?(args, &1)) -> args
      run -> Map.put(args, "run", run)
      pr -> Map.put(args, "pr", pr)
      true -> args
    end
  end

  defp target(args, next_run?) do
    given = for k <- ~w(pr branch run), Map.has_key?(args, k), do: k

    case given do
      ["run"] when next_run? ->
        {:error, "next_run applies to a pr or branch, not a run."}

      ["branch"] ->
        if String.trim(args["branch"]) == "",
          do: {:error, "branch is empty"},
          else: {:ok, "branch", String.trim(args["branch"])}

      [k] ->
        {:ok, k, args[k]}

      _ ->
        {:error, "Give exactly one of pr, branch or run."}
    end
  end

  defp prepare_error({:error, {:repo, reason}}, _scope, ref),
    do: {:error, Repos.problem(ref, reason)}

  defp prepare_error({:error, :not_found}, _scope, ref),
    do: {:error, "That pr, branch or run doesn't exist in #{Ref.full(ref)}, or you can't see it."}

  defp prepare_error({:error, reason}, _scope, ref), do: {:error, Repos.problem(ref, reason)}
  defp prepare_error(ok, _scope, _ref), do: ok

  # Without next_run, a run that already finished is answered now instead of watched.
  defp not_done_yet(_scope, _target, _state, true), do: :ok

  defp not_done_yet(scope, target, state, false) do
    case CI.check(scope, %{target: target, last_state: state}) do
      {:done, %{"result" => result, "runs" => [run | _]}} ->
        {:error,
         "CI for this already finished: #{result} (#{run["url"]}). Nothing to watch; use " <>
           "next_run to wait for the next run, or ci_failure for the details."}

      _ ->
        :ok
    end
  end
end
