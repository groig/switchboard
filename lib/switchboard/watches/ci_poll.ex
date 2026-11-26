defmodule Switchboard.Watches.CiPoll do
  @moduledoc """
  Checks one CI watch with its owner's Forgejo token, then schedules the next check: about a
  minute after creation, then 30 s later each time, up to every 5 minutes. A Forgejo webhook moves
  the scheduled check to now (`Switchboard.Watches.Hint`); the check itself never trusts the
  webhook, it reads Forgejo again.

  Unique per watch while waiting, so the webhook, the sweep's recovery and the job's own
  rescheduling never stack checks.
  """
  use Oban.Worker,
    queue: :watches,
    max_attempts: 3,
    unique: [keys: [:watch_id], period: :infinity, states: [:available, :scheduled, :retryable]]

  alias Switchboard.Controls
  alias Switchboard.Watches
  alias Switchboard.Watches.{CI, Watch}

  @min_delay 60
  @max_delay 300

  @doc "A check job for a watch, `in_seconds` from now."
  def new_for(%Watch{id: id}, in_seconds), do: new(%{watch_id: id}, schedule_in: in_seconds)

  @doc "Moves a watch's waiting check to now (a webhook hint)."
  def now(id),
    do:
      new(%{watch_id: id},
        scheduled_at: DateTime.utc_now(),
        replace: [scheduled: [:scheduled_at]]
      )

  def delay(checks), do: min(@min_delay + checks * 30, @max_delay)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"watch_id" => id}}) do
    case Watches.get(id) do
      %Watch{status: "active", kind: "ci"} = watch -> check(watch)
      _ -> :ok
    end
  end

  defp check(watch) do
    cond do
      Controls.watches_paused?() ->
        reschedule(watch, @max_delay)

      DateTime.compare(DateTime.utc_now(), watch.expires_at) != :lt ->
        Watches.expire(watch)
        :ok

      true ->
        case CI.check(Watches.scope_for(watch.user), watch) do
          {:pending, state} ->
            Watches.checked(watch, state)
            reschedule(watch, delay(watch.checks + 1))

          {:done, %{"result" => "success"} = state} ->
            if watch.options["only_on_failure"],
              do: Watches.finish_quietly(watch, state, "succeeded_quietly"),
              else: Watches.notify(watch, state)

            :ok

          {:done, state} ->
            Watches.notify(watch, state)
            :ok

          {:stop, reason} ->
            Watches.stop(watch, reason)
            :ok

          {:retry, _reason} ->
            Watches.checked(watch)
            reschedule(watch, delay(watch.checks + 1))
        end
    end
  end

  # The current job is executing, so this insert doesn't conflict with itself; it does collapse
  # into a check a webhook already scheduled (that one keeps its earlier time).
  defp reschedule(watch, seconds) do
    {:ok, _} = Oban.insert(new_for(watch, seconds))
    :ok
  end
end
