defmodule Switchboard.Tools.PlaneSetState do
  @moduledoc "Moves a Plane work item to another state, by state name."
  use Switchboard.Tools.Support

  alias Switchboard.Plane

  @impl true
  def name, do: "plane_set_state"
  @impl true
  def title, do: "Change a Plane item's state"
  @impl true
  def description,
    do:
      "Moves a Plane work item to another state of its project (e.g. \"In Review\"), as you. " <>
        "The name is checked against the project's states. This writes to Plane: before " <>
        "calling it, show the user the item, its current state and the new one, and get their " <>
        "explicit OK (confirm first). Returns the old and new state."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "id" => %{"type" => "string", "description" => "Work item identifier, e.g. PROJ-123."},
        "state" => %{"type" => "string", "description" => "Target state name, as shown in Plane."}
      },
      "required" => ["id", "state"]
    }
  end

  @impl true
  def annotations, do: %{read_only: false, destructive: false, idempotent: true, open_world: true}
  @impl true
  def connections, do: [:plane]

  @impl true
  def aliases, do: Map.put(Switchboard.Tools.Support.task_aliases("id"), "status", "state")

  @impl true
  def example do
    %{
      args: %{"id" => "DEMO-12", "state" => "In Review"},
      output:
        "DEMO-12 (Export invoices as CSV): In Progress → **In Review**. https://projects.example.com/demo/browse/DEMO-12/"
    }
  end

  @impl true
  def call(scope, %{"id" => id, "state" => wanted}) do
    id = id |> String.trim() |> String.upcase()

    with true <- Plane.identifier?(id) || {:error, "id must look like PROJECT-123"},
         {:ok, cred} <- cred(scope, :plane),
         {:ok, item} <- Plane.fresh_item(cred, id) |> lift(id),
         {:ok, states} <- Plane.states(cred, scope.user.id, item["project"]) |> lift(id),
         {:ok, target} <- match_state(states, wanted) do
      old = get_in(item, ["state", "name"]) || "?"

      cond do
        target["id"] == get_in(item, ["state", "id"]) ->
          {:ok, "#{id} is already in **#{target["name"]}**; nothing changed."}

        true ->
          case Plane.set_state(cred, item, target["id"]) do
            {:ok, _} ->
              {:ok,
               "#{id} (#{cell(item["name"], 100)}): #{cell(old)} → **#{cell(target["name"])}**. #{Plane.browse_url(id)}"}

            {:error, reason} ->
              {:error, problem(:plane, reason)}
          end
      end
    end
  end

  defp match_state(states, wanted) do
    norm = &(&1 |> to_string() |> String.trim() |> String.downcase())

    case Enum.find(states, &(norm.(&1["name"]) == norm.(wanted))) do
      nil ->
        names = states |> Enum.map(& &1["name"]) |> Enum.join(", ")
        {:error, "\"#{cell(wanted)}\" is not a state of this project. Its states: #{names}."}

      state ->
        {:ok, state}
    end
  end

  defp lift({:error, :not_found}, id),
    do: {:error, "Plane has no work item #{id}, or you can't see it."}

  defp lift({:error, reason}, _id), do: {:error, problem(:plane, reason)}
  defp lift(ok, _id), do: ok
end
