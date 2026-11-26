defmodule Switchboard.Tools.WatchSupport do
  @moduledoc "Shared pieces of the watch tools: creation, the lines they answer, descriptions."
  import Switchboard.Tools.Support, only: [time: 2]

  alias Switchboard.Watches
  alias Switchboard.Watches.Watch
  alias Switchboard.Tools.NotifyMe

  @doc "The `hours` argument schema."
  def hours_schema,
    do: %{
      "type" => "integer",
      "description" =>
        "How long to watch, in hours (default #{Watches.default_hours()}, max #{Watches.max_hours()})."
    }

  def hours(args) do
    case Map.get(args, "hours", Watches.default_hours()) do
      n when is_integer(n) and n >= 1 and n <= 168 -> {:ok, n}
      _ -> {:error, "hours must be between 1 and #{Watches.max_hours()}"}
    end
  end

  @doc "The Rocket.Chat user notices will go to (the caller), or why there is none."
  def recipient(scope), do: NotifyMe.recipient(scope)

  @doc "Creates the watch and answers in one line, or explains the refusal."
  def create(scope, attrs, username, waits_for) do
    case Watches.create(scope, attrs) do
      {:ok, watch} ->
        {:ok,
         "Watching #{Watch.label(watch)}: Switchboard will DM you in Rocket.Chat (as @#{username}) " <>
           "#{waits_for}. Expires #{time(watch.expires_at, scope)}. Watch id: `#{watch.id}` " <>
           "(list_watches, cancel_watch, or #{Switchboard.Watches.Notice.watches_url()})."}

      {:error, :paused} ->
        {:error, "Watches are paused by an administrator right now."}

      {:error, :limit} ->
        {:error,
         "You already have #{Watches.max_active()} active watches, the limit. Cancel one first (list_watches)."}

      {:error, {:duplicate, watch}} ->
        {:error,
         "You already watch #{Watch.label(watch)} (watch id `#{watch.id}`, expires #{time(watch.expires_at, scope)})."}
    end
  end

  @doc "What a watch waits for, in a few words."
  def waits_for(%Watch{kind: "ci", options: o}) do
    base = if o["next_run"], do: "the next CI run", else: "CI"
    if o["only_on_failure"], do: base <> " (only if it fails)", else: base
  end

  def waits_for(%Watch{kind: "task", options: o}) do
    case o["until"] do
      "done" -> "done"
      "released" -> "released"
      _ -> "any change"
    end
  end

  def waits_for(%Watch{kind: "release", options: o}),
    do: if(o["health"], do: "next release + 24 h health", else: "next release")

  @doc "How a watch ended (or its phase), in a few words."
  def outcome(%Watch{status: "active", last_state: %{"phase" => "health"}}),
    do: "waiting for health"

  def outcome(%Watch{status: "active"}), do: "active"
  def outcome(%Watch{status: "cancelled"}), do: "cancelled"

  def outcome(%Watch{end_reason: reason}) do
    case reason do
      "notified" -> "notified"
      "succeeded_quietly" -> "passed (no notice)"
      "timed_out" -> "expired"
      "connection_missing" -> "stopped: connection missing"
      "connection_rejected" -> "stopped: key rejected"
      "access_lost" -> "stopped: no access"
      other -> other || "ended"
    end
  end
end
