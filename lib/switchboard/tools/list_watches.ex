defmodule Switchboard.Tools.ListWatches do
  @moduledoc "The caller's own watches: active ones and those that ended recently."
  use Switchboard.Tools.Support

  alias Switchboard.Tools.WatchSupport
  alias Switchboard.Watches
  alias Switchboard.Watches.Watch

  @impl true
  def name, do: "list_watches"
  @impl true
  def title, do: "My watches"
  @impl true
  def description,
    do:
      "Use when the user asks what they are watching. Lists their own watches (watch_ci, " <>
        "watch_task, watch_release): active ones and those that ended in the last 14 days, with " <>
        "what each waits for, its expiry and how it ended. Ids are for cancel_watch."

  @impl true
  def input_schema, do: %{"type" => "object", "properties" => %{}}

  @impl true
  def annotations, do: %{read_only: true, open_world: false}
  @impl true
  def connections, do: []

  @impl true
  def example do
    %{
      args: %{},
      output: """
      ## Your watches (1 active of 20)

      | Id | Kind | What | Waits for | Status | Expires / ended |
      |---|---|---|---|---|---|
      | `5b1c0d2e-…` | ci | demo/app#42 | the next CI run | active | 2026-11-27 10:00 (Europe/Madrid) |
      """
    }
  end

  @impl true
  def call(scope, _args) do
    watches = Watches.list(scope.user)
    active = Enum.count(watches, &(&1.status == "active"))

    if watches == [] do
      {:ok, "You have no watches. Create one with watch_ci, watch_task or watch_release."}
    else
      rows =
        Enum.map(watches, fn w ->
          [
            "`#{w.id}`",
            w.kind,
            cell(Watch.label(w), 80),
            WatchSupport.waits_for(w),
            WatchSupport.outcome(w),
            time(if(w.status == "active", do: w.expires_at, else: w.ended_at), scope)
          ]
        end)

      {:ok,
       "## Your watches (#{active} active of #{Watches.max_active()})\n\n" <>
         table(["Id", "Kind", "What", "Waits for", "Status", "Expires / ended"], rows)}
    end
  end
end
