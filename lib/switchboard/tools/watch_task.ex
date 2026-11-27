defmodule Switchboard.Tools.WatchTask do
  @moduledoc "Watch a Plane work item: DM when it changes state, is done, or ships in a release."
  use Switchboard.Tools.Support

  alias Switchboard.{Plane, Releases}
  alias Switchboard.Tools.WatchSupport
  alias Switchboard.Watches.ReleaseCheck

  @impl true
  def name, do: "watch_task"
  @impl true
  def title, do: "Watch a task"
  @impl true
  def description,
    do:
      "Use when the user wants to be told when a Plane work item (PROJ-123) changes, is done, " <>
        "or ships to production. Sends the user (only them) a Rocket.Chat DM. Checked every " <>
        "5 minutes with their own Plane key. It only notifies the user who asked, so their " <>
        "request is the confirmation."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "id" => %{"type" => "string", "description" => "Work item id, e.g. PROJ-123."},
        "until" => %{
          "type" => "string",
          "enum" => ["any_change", "done", "released"],
          "description" =>
            "any_change (default: a state change or a release), done, or released (ships in a production release)."
        },
        "hours" => WatchSupport.hours_schema()
      },
      "required" => ["id"]
    }
  end

  @impl true
  def annotations,
    do: %{read_only: false, destructive: false, idempotent: false, open_world: true}

  @impl true
  def connections, do: [:plane]

  @impl true
  def aliases, do: Switchboard.Tools.Support.task_aliases("id")

  @impl true
  def example do
    %{
      args: %{"id" => "DEMO-12", "until" => "released", "hours" => 72},
      output:
        "Watching DEMO-12: Switchboard will DM you in Rocket.Chat (as @ana) when it ships in " <>
          "a production release. Expires 2026-11-29 10:00 (Europe/Madrid). Watch id: `5b1c…` " <>
          "(list_watches, cancel_watch, or https://switchboard.example.com/watches)."
    }
  end

  @impl true
  def call(scope, %{"id" => id} = args) do
    id = id |> String.trim() |> String.upcase()
    until = args["until"] || "any_change"

    with true <- Plane.identifier?(id) || {:error, "id must look like PROJECT-123"},
         {:ok, hours} <- WatchSupport.hours(args),
         {:ok, username} <- WatchSupport.recipient(scope),
         {:ok, cred} <- cred(scope, :plane),
         {:ok, item} <- Plane.item(cred, id) |> plane_error(id),
         :ok <- not_done(item, until, id),
         {:ok, shipped} <- shipped_baseline(id, until) do
      state = item["state"] || %{}

      WatchSupport.create(
        scope,
        %{
          kind: "task",
          target: %{"id" => id},
          subject: id,
          options: %{"until" => until},
          hours: hours,
          state: %{
            "state_id" => state["id"],
            "state" => state["name"],
            "group" => state["group"],
            "url" => Plane.browse_url(id),
            "shipped_baseline" => shipped
          }
        },
        username,
        case until do
          "done" -> "when it is done"
          "released" -> "when it ships in a production release"
          _ -> "when it changes state or ships in a release"
        end
      )
    end
  end

  defp plane_error({:error, :not_found}, id),
    do: {:error, "Plane has no work item #{id}, or you can't see it."}

  defp plane_error({:error, reason}, _id), do: {:error, problem(:plane, reason)}
  defp plane_error(ok, _id), do: ok

  defp not_done(item, "done", id) do
    if get_in(item, ["state", "group"]) in ["completed", "cancelled"],
      do: {:error, "#{id} is already #{get_in(item, ["state", "name"])}. Nothing to watch."},
      else: :ok
  end

  defp not_done(_item, _until, _id), do: :ok

  defp shipped_baseline(_id, "done"), do: {:ok, []}

  defp shipped_baseline(id, _until) do
    case Releases.list(limit: 200) do
      {:ok, releases} -> {:ok, ReleaseCheck.shipped_baseline(releases, id)}
      {:error, reason} -> {:error, problem(:releases, reason)}
    end
  end
end
