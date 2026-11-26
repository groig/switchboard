defmodule Switchboard.Tools.Workflow do
  @moduledoc """
  Runs a team workflow (`Switchboard.Workflows`) and returns the same text as the MCP prompt of
  that name, for clients that don't offer prompts as slash commands. Audited once, as
  `workflow:<name>`, by `Switchboard.Workflows.run/4`.
  """
  use Switchboard.Tools.Support

  alias Switchboard.Workflows

  @impl true
  def name, do: "workflow"
  @impl true
  def title, do: "Team workflow"

  @impl true
  def description do
    list =
      Enum.map_join(Workflows.all(), "; ", fn mod ->
        "#{Workflows.usage(mod) |> usage()}: #{mod.description()}"
      end)

    "Runs a team workflow: Switchboard fetches the facts with the user's own credentials and " <>
      "returns step-by-step instructions for you to follow. Use it when the user asks for one of " <>
      "these (in any words, e.g. \"do my standup\"), then follow the returned steps: " <>
      list <>
      ". The workflow itself changes nothing; any write it suggests is proposed to the user " <>
      "and needs their OK first."
  end

  defp usage("Usage: " <> rest), do: rest

  @impl true
  def input_schema do
    args =
      Workflows.all()
      |> Enum.flat_map(& &1.arguments())
      |> Enum.uniq_by(& &1.name)
      |> Enum.map_join(", ", & &1.name)

    %{
      "type" => "object",
      "properties" => %{
        "name" => %{
          "type" => "string",
          "enum" => Workflows.names(),
          "description" => "The workflow."
        },
        "args" => %{
          "type" => "object",
          "description" =>
            "The workflow's arguments as text, e.g. {\"task\": \"PROJ-123\"} (#{args}).",
          "additionalProperties" => %{"type" => "string"}
        }
      },
      "required" => ["name"]
    }
  end

  @impl true
  def annotations, do: %{read_only: true, open_world: true}
  @impl true
  def connections, do: [:plane, :forgejo, :argus, :outline, :rocketchat]

  @impl true
  def example do
    %{
      args: %{"name" => "pickup", "args" => %{"task" => "DEMO-12"}},
      output: """
      # pickup: Start working on a task

      Team workflow `pickup` for Ana García (@ana), run Thursday 2026-11-26 09:30 (Europe/Madrid). Switchboard fetched the facts below with their own credentials and changed nothing.

      ## What to do

      1. Summarize what DEMO-12 asks for and what is unclear ...

      ## Rules

      - **Never write anything on your own.** ...

      ## Facts

      ### The task
      ...
      """
    }
  end

  @impl true
  def call(scope, %{"name" => name} = args) do
    Workflows.run(scope, name, Map.get(args, "args") || %{}, :tool)
  end
end
