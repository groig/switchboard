defmodule Switchboard.Tools.WatchCi do
  @moduledoc "Watch a pull request's, branch's or Actions run's CI; DM the result when it finishes."
  use Switchboard.Tools.Support

  alias Switchboard.Forgejo
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
        "Watches a Forgejo pull request, branch or Actions run and sends the user (only them) a " <>
        "Rocket.Chat DM with the result, the link and the failed job and step. Use next_run " <>
        "right after a push. It only notifies the user who asked, so their request is the " <>
        "confirmation."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "repo" => %{"type" => "string", "description" => "owner/name."},
        "pr" => %{"type" => "integer", "description" => "Pull request number."},
        "branch" => %{"type" => "string", "description" => "Branch name."},
        "run" => %{"type" => "integer", "description" => "Actions run number."},
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
  def connections, do: [:forgejo]

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

    with {:ok, owner, name} <- repo_ok(Forgejo.parse_repo(repo)),
         {:ok, kind, value} <- target(args, next_run?),
         {:ok, hours} <- WatchSupport.hours(args),
         {:ok, username} <- WatchSupport.recipient(scope),
         {:ok, target, state} <-
           CI.prepare(scope, owner, name, kind, value, next_run?) |> forgejo_error(repo),
         :ok <- not_done_yet(scope, target, state, next_run?) do
      WatchSupport.create(
        scope,
        %{
          kind: "ci",
          target: target,
          subject: String.downcase("#{owner}/#{name}"),
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

  defp repo_ok({:error, :invalid_repo}), do: {:error, "repo must be owner/name"}
  defp repo_ok(ok), do: ok

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

  defp forgejo_error({:error, :not_found}, repo),
    do: {:error, "#{repo}, or that pr/branch/run, doesn't exist or you can't see it."}

  defp forgejo_error({:error, reason}, _repo), do: {:error, problem(:forgejo, reason)}
  defp forgejo_error(ok, _repo), do: ok

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
