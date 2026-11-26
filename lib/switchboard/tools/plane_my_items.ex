defmodule Switchboard.Tools.PlaneMyItems do
  @moduledoc "Open Plane work items assigned to the caller."
  use Switchboard.Tools.Support

  alias Switchboard.Plane

  @impl true
  def name, do: "plane_my_items"
  @impl true
  def title, do: "My Plane items"
  @impl true
  def description,
    do:
      "Lists the open Plane work items assigned to you (backlog, to do, in progress) in the " <>
        "projects you are a member of, grouped by state, overdue and urgent first."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "state" => %{
          "type" => "string",
          "enum" => ["open", "started"],
          "description" =>
            "open (default): backlog, to do and in progress; started: in progress only."
        }
      }
    }
  end

  @impl true
  def annotations, do: %{read_only: true, open_world: true}
  @impl true
  def connections, do: [:plane]

  @impl true
  def example do
    %{
      args: %{},
      output: """
      ## My Plane items (3 open)

      ### In Progress

      | ID | Title | Priority | Due |
      |---|---|---|---|
      | DEMO-12 | Export invoices as CSV | high | 2026-11-30 |

      ### Todo

      | ID | Title | Priority | Due |
      |---|---|---|---|
      | DEMO-15 | Rounding in tax totals | urgent | 2026-11-27 (overdue) |
      | DEMO-9 | Remove legacy export | low | – |
      """
    }
  end

  @impl true
  def call(scope, args) do
    with {:ok, cred} <- cred(scope, :plane) do
      case Plane.my_items(cred, scope.user.id) do
        {:ok, items, notes} ->
          items =
            if args["state"] == "started",
              do: Enum.filter(items, &(get_in(&1, ["state", "group"]) == "started")),
              else: items

          {:ok, render(items) |> with_notes(notes) |> Markdown.cap()}

        {:error, reason} ->
          {:error, problem(:plane, reason)}
      end
    end
  end

  @group_order %{"started" => 0, "unstarted" => 1, "backlog" => 2}

  @doc false
  def render([]), do: "## My Plane items\n\nNothing open is assigned to you."

  def render(items) do
    today = Date.utc_today()

    sections =
      items
      |> Enum.group_by(&(get_in(&1, ["state", "name"]) || "?"))
      |> Enum.sort_by(fn {name, group} ->
        {group
         |> Enum.map(&Map.get(@group_order, get_in(&1, ["state", "group"]), 3))
         |> Enum.min(), name}
      end)
      |> Enum.map_join("\n\n", fn {state, group} ->
        rows =
          group
          |> Plane.sort_items(today)
          |> Enum.map(fn i ->
            [
              i["identifier"],
              cell(i["name"], 90),
              cell(i["priority"]),
              due(i["target_date"], today)
            ]
          end)

        "### #{cell(state)}\n\n" <> table(["ID", "Title", "Priority", "Due"], rows)
      end)

    "## My Plane items (#{length(items)} open)\n\n" <> sections
  end

  defp due(nil, _today), do: "–"

  defp due(date, today) do
    d = String.slice(date, 0, 10)

    case Date.from_iso8601(d) do
      {:ok, dd} -> if Date.before?(dd, today), do: "#{d} (overdue)", else: d
      _ -> d
    end
  end
end
