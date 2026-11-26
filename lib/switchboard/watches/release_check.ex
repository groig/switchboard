defmodule Switchboard.Watches.ReleaseCheck do
  @moduledoc """
  Release and "shipped" decisions, as pure functions over the releases feed (newest first). The
  sweep reads the feed once a minute and shares it between every watch.

    * A release watch records, at creation, the releases of its repo that had already finished
      (`baseline`). The next release is the oldest one not in it that reaches `success`,
      `failure` or `cancelled` (`skipped` releases don't count). With `health`, the watch then
      waits for the release's 24 h window (`watching` false, `health` set; at most 26 h).
    * A task watch records which releases had already shipped the task; a new one ships it.
  """
  alias Switchboard.Releases

  @terminal ~w(success failure cancelled)
  @health_wait 26 * 3600

  @doc "Baseline for a new release watch: names of the repo's finished releases."
  def baseline(releases, repo) do
    for r <- releases, r["repo"] == repo, r["status"] not in ["deploying"], do: r["name"]
  end

  @doc "Baseline for a new task watch: releases that already shipped it."
  def shipped_baseline(releases, id), do: Enum.map(Releases.shipping(id, releases), & &1["name"])

  @doc """
  For a release watch: `{:result, state, health_until}` (with `health_until` nil unless it waits
  for health), `{:health, state}`, or `:wait`.
  """
  def evaluate(%{target: %{"repo" => repo}, options: opts, last_state: last}, releases, now) do
    case last["phase"] do
      "health" -> health(last, releases, now)
      _ -> next_release(repo, opts, last, releases)
    end
  end

  defp next_release(repo, opts, last, releases) do
    baseline = last["baseline"] || []

    releases
    |> Enum.filter(&(&1["repo"] == repo and &1["name"] not in baseline))
    |> Enum.filter(&(&1["status"] in @terminal))
    |> List.last()
    |> case do
      nil ->
        :wait

      r ->
        health? = opts["health"] == true and r["status"] == "success"

        state = %{
          "repo" => repo,
          "name" => r["name"],
          "status" => r["status"],
          "run_url" => r["runUrl"],
          "card_url" => r["cardUrl"],
          "highlights" => r["highlights"],
          "finished" => r["finishedAt"] || r["startedAt"],
          "baseline" => baseline,
          "phase" => if(health?, do: "health", else: "done")
        }

        until =
          if health?,
            do: DateTime.add(parse(state["finished"]) || DateTime.utc_now(), @health_wait),
            else: nil

        {:result, state, until}
    end
  end

  defp health(last, releases, now) do
    release = Enum.find(releases, &(&1["name"] == last["name"] and &1["repo"] == last["repo"]))
    finished = parse(last["finished"])

    window_over? =
      match?(%{"watching" => false, "health" => h} when is_binary(h), release)

    late? = finished && DateTime.diff(now, finished) >= @health_wait

    if window_over? or late? do
      issues =
        for i <- (release && release["argusIssues"]) || [],
            i["fromRelease"] == true,
            do: %{"title" => i["title"], "url" => i["url"]}

      {:health,
       Map.merge(last, %{
         "phase" => "done",
         "health" => release && release["health"],
         "issues" => Enum.take(issues, 5)
       })}
    else
      :wait
    end
  end

  @doc "For a task watch: `{:released, state}` when a release not in its baseline shipped it."
  def shipped(%{target: %{"id" => id}, last_state: last}, releases) do
    baseline = last["shipped_baseline"] || []

    case id
         |> Releases.shipping(releases)
         |> Enum.reject(&(&1["name"] in baseline))
         |> List.last() do
      nil ->
        :wait

      r ->
        {:released,
         Map.merge(last, %{
           "event" => "released",
           "release" => r["name"],
           "release_repo" => r["repo"]
         })}
    end
  end

  defp parse(nil), do: nil

  defp parse(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end
