defmodule Switchboard.Watches.Hint do
  @moduledoc """
  A verified Forgejo webhook said something finished in a repo. This only moves the waiting
  checks of that repo's CI watches to now; each check reads Forgejo again with its owner's own
  token (`Switchboard.Watches.CiPoll`), so a forged, stale or replayed webhook can't cause a
  notice, and nobody learns anything about a repo they can't see.

  Watches checked in the last 10 seconds are skipped, so a burst of webhooks costs one check.
  """
  use Oban.Worker,
    queue: :watches,
    max_attempts: 1,
    unique: [keys: [:repo], period: 10, states: [:available, :scheduled]]

  alias Switchboard.Watches
  alias Switchboard.Watches.CiPoll

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"repo" => repo}}) when is_binary(repo) do
    recent = DateTime.add(DateTime.utc_now(), -10)

    for watch <- Watches.active("ci", String.downcase(repo)),
        is_nil(watch.last_checked_at) or DateTime.compare(watch.last_checked_at, recent) == :lt do
      Oban.insert(CiPoll.now(watch.id))
    end

    :ok
  end
end
