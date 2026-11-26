defmodule Switchboard.Watches.Deliver do
  @moduledoc """
  Sends one watch notice (`"result"` or `"health"`) to the watch's owner, from the bot user.

  At most once, whatever happens to the job:

    1. the job is unique per watch and notice, for good (`states: :all`);
    2. before calling Rocket.Chat it claims the notice in `watches.deliveries` with a
       conditional update; a retried or rescued job that finds the claim does nothing;
    3. a failure that certainly posted nothing (`{:not_sent, _}`) releases the claim and retries;
       a timeout on the post itself (`{:unsure, _}`) keeps it, so nobody gets the DM twice.

  Each person gets at most #{30} watch notices an hour; past that, notices wait (snooze).
  While watches are paused (admin), notices wait too.
  """
  use Oban.Worker,
    queue: :watches,
    max_attempts: 5,
    unique: [keys: [:watch_id, :notice], period: :infinity, states: :all]

  import Ecto.Query

  alias Switchboard.{Controls, RateLimit, Repo, RocketChat, Watches}
  alias Switchboard.Tools.NotifyMe
  alias Switchboard.Watches.{Notice, Watch}

  require Logger

  @per_hour 30

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"watch_id" => id, "notice" => notice}})
      when notice in ["result", "health"] do
    case Watches.get(id) do
      nil ->
        :ok

      %Watch{deliveries: %{^notice => _}} ->
        :ok

      watch ->
        cond do
          Controls.watches_paused?() -> {:snooze, 300}
          not hourly?(watch) -> {:snooze, 600}
          true -> send_notice(watch, notice)
        end
    end
  end

  defp hourly?(watch),
    do: RateLimit.take({watch.user_id, :watch_notices}, @per_hour, :timer.hours(1)) == :ok

  defp send_notice(watch, notice) do
    scope = Watches.scope_for(watch.user)

    with {:ok, username} <- NotifyMe.recipient(scope) |> no_recipient(watch),
         :claimed <- claim(watch, notice) do
      text = Notice.render(watch, notice)

      case RocketChat.deliver(username, NotifyMe.notice(scope, text)) do
        :ok ->
          mark(watch, notice, "sent")
          :ok

        {:error, {:not_sent, reason}} ->
          release(watch, notice)
          {:error, reason}

        {:error, {:unsure, reason}} ->
          mark(watch, notice, "unsure")

          Logger.warning(
            "Watch #{watch.id} #{notice} notice may not have arrived: #{inspect(reason)}"
          )

          {:cancel, reason}
      end
    end
  end

  defp no_recipient({:ok, _} = ok, _watch), do: ok

  defp no_recipient({:error, _message}, watch) do
    Logger.warning("Watch #{watch.id}: no Rocket.Chat user to notify")
    {:cancel, :no_recipient}
  end

  defp claim(watch, notice) do
    {n, _} =
      from(w in Watch,
        where: w.id == ^watch.id and is_nil(fragment("? ->> ?", w.deliveries, ^notice)),
        update: [
          set: [
            deliveries:
              fragment("? || jsonb_build_object(?::text, 'sending')", w.deliveries, ^notice)
          ]
        ]
      )
      |> Repo.update_all([])

    if n == 1, do: :claimed, else: :ok
  end

  defp mark(watch, notice, value) do
    from(w in Watch,
      where: w.id == ^watch.id,
      update: [
        set: [
          deliveries:
            fragment("? || jsonb_build_object(?::text, ?::text)", w.deliveries, ^notice, ^value)
        ]
      ]
    )
    |> Repo.update_all([])
  end

  defp release(watch, notice) do
    from(w in Watch,
      where: w.id == ^watch.id,
      update: [set: [deliveries: fragment("? - ?::text", w.deliveries, ^notice)]]
    )
    |> Repo.update_all([])
  end
end
