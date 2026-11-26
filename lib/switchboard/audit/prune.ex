defmodule Switchboard.Audit.Prune do
  @moduledoc "Daily Oban job that applies the audit log retention."
  use Oban.Worker, queue: :default, max_attempts: 3

  @impl Oban.Worker
  def perform(_job) do
    Switchboard.Audit.prune()
    :ok
  end
end
