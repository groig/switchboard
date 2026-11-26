defmodule Switchboard.Watches.Sweep do
  @moduledoc """
  Every minute (Oban cron, so on one node only):

    1. expires watches past their time, each with its final notice;
    2. re-creates the check job of any active CI watch that lost it (recovery after a crash);
    3. reads the releases feed **once** for everyone and decides release watches and the
       "shipped" part of task watches;
    4. queues `Switchboard.Watches.TaskPoll` for each person with Plane task watches not checked
       in the last 5 minutes (one job per person, so their watches share one pass with one key).

  Does nothing while watches are paused.
  """
  use Oban.Worker, queue: :watches, max_attempts: 1, unique: [period: 50]

  alias Switchboard.{Controls, Releases}
  alias Switchboard.Watches
  alias Switchboard.Watches.{CiPoll, ReleaseCheck, TaskPoll}

  require Logger

  @task_interval 300

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if Controls.watches_paused?() do
      :ok
    else
      now = DateTime.utc_now()
      Watches.expire_due(now)
      recover_ci()
      releases(now)
      queue_task_polls(now)
      :ok
    end
  end

  defp recover_ci do
    for watch <- Watches.active("ci"), do: Oban.insert(CiPoll.new_for(watch, 0))
  end

  defp releases(now) do
    release_watches = Watches.active("release")

    task_watches =
      Enum.filter(
        Watches.active("task"),
        &(&1.options["until"] in ["any_change", "released", nil])
      )

    if release_watches != [] or task_watches != [] do
      case Releases.list(limit: 100) do
        {:ok, feed} ->
          Enum.each(release_watches, &release(&1, feed, now))
          Enum.each(task_watches, &shipped(&1, feed))

        {:error, reason} ->
          Logger.warning("Watches: releases feed unavailable: #{inspect(reason)}")
      end
    end
  end

  defp release(watch, feed, now) do
    case ReleaseCheck.evaluate(watch, feed, now) do
      {:result, state, nil} -> Watches.notify(watch, state)
      {:result, state, until} -> Watches.notify(watch, state, health: true, until: until)
      {:health, state} -> Watches.notify_health(watch, state)
      :wait -> :ok
    end
  end

  defp shipped(watch, feed) do
    case ReleaseCheck.shipped(watch, feed) do
      {:released, state} ->
        Watches.notify(watch, Map.put(state, "url", Switchboard.Plane.browse_url(watch.subject)))

      :wait ->
        :ok
    end
  end

  defp queue_task_polls(now) do
    due = DateTime.add(now, -@task_interval + 10)

    Watches.active("task")
    |> Enum.filter(&(&1.options["until"] != "released"))
    |> Enum.filter(
      &(is_nil(&1.last_checked_at) or DateTime.compare(&1.last_checked_at, due) == :lt)
    )
    |> Enum.map(& &1.user_id)
    |> Enum.uniq()
    |> Enum.each(&Oban.insert(TaskPoll.new(%{user_id: &1})))
  end
end
