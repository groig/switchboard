defmodule Switchboard.Watches.TaskPoll do
  @moduledoc """
  One pass over one person's Plane task watches, with their own Plane key through
  `Switchboard.Plane` (cached). At most one item read per watch every 5 minutes: with the
  20-watch limit that is 4 requests a minute at worst, well inside the key's ~60 a minute shared
  with the person's other tools. A rate-limited or unreachable Plane just waits for the next pass.
  """
  use Oban.Worker,
    queue: :watches,
    max_attempts: 1,
    unique: [keys: [:user_id], period: 240, states: :incomplete]

  alias Switchboard.{Plane, Upstreams}
  alias Switchboard.Watches
  alias Switchboard.Watches.{CI, Watch}

  @done_groups ~w(completed cancelled)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    watches =
      Watches.active("task")
      |> Enum.filter(&(&1.user_id == user_id and &1.options["until"] != "released"))

    with [%Watch{user: user} | _] <- watches do
      scope = Watches.scope_for(user)

      case Upstreams.credential(scope, :plane) do
        {:ok, cred} ->
          Enum.each(watches, &check(&1, cred))

        {:error, reason} ->
          {:stop, end_reason} = CI.problem(reason)
          Enum.each(watches, &Watches.stop(&1, end_reason))
      end
    end

    :ok
  end

  defp check(watch, cred) do
    case Plane.item(cred, watch.subject) do
      {:ok, item} -> compare(watch, item)
      {:error, reason} -> problem(watch, reason)
    end
  end

  defp problem(watch, reason) do
    case CI.problem(reason) do
      {:stop, end_reason} -> Watches.stop(watch, end_reason)
      {:retry, _} -> Watches.checked(watch)
    end
  end

  defp compare(watch, item) do
    state = item["state"] || %{}
    last = watch.last_state

    seen =
      Map.merge(last, %{
        "state_id" => state["id"],
        "state" => state["name"],
        "group" => state["group"],
        "url" => Plane.browse_url(watch.subject)
      })

    changed? = state["id"] != last["state_id"]

    cond do
      not changed? ->
        Watches.checked(watch, seen)

      watch.options["until"] == "done" and state["group"] not in @done_groups ->
        # Moved, but not to done: remember where it is now, keep waiting.
        Watches.checked(watch, seen)

      true ->
        Watches.notify(
          watch,
          Map.merge(seen, %{"event" => "state", "previous_state" => last["state"]})
        )
    end
  end
end
