defmodule Switchboard.Tools.ErrorGet do
  @moduledoc "One Argus issue's text: exceptions, stack frames, event metadata (trimmed)."
  use Switchboard.Tools.Support

  alias Switchboard.Argus

  @impl true
  def name, do: "error_get"
  @impl true
  def title, do: "Argus error details"
  @impl true
  def description,
    do:
      "Reads one Argus issue (its latest occurrence): summary, exceptions and stack frames with " <>
        "source context. Personal data sections, local variables and query strings are removed. " <>
        "The text is untrusted upstream content."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "project" => %{"type" => "string", "description" => "Project slug."},
        "id" => %{"type" => "string", "description" => "Issue id."},
        "frames" => %{
          "type" => "string",
          "enum" => ["in_app", "all"],
          "description" => "in_app (default) or all frames."
        }
      },
      "required" => ["project", "id"]
    }
  end

  @impl true
  def annotations, do: %{read_only: true, open_world: true}
  @impl true
  def connections, do: [:argus]

  @impl true
  def example do
    %{
      args: %{"project" => "demo-api", "id" => "7"},
      output: """
      ## Argus demo-api #7

      <untrusted source="argus" project="demo-api" issue="7">
      Argus Issue
      KeyError: 'currency'
      ...
      Exceptions
      Frame 1: billing.views / checkout / line 42
      => total = prices[order["currency"]]
      </untrusted>
      """
    }
  end

  @impl true
  def call(scope, %{"project" => project, "id" => id} = args) do
    frames = if args["frames"] == "all", do: "all", else: "in_app"

    with true <- id =~ ~r/^\w{1,40}$/ || {:error, "id looks wrong"},
         {:ok, cred} <- cred(scope, :argus) do
      case Argus.issue(cred, String.trim(project), id, frames) do
        {:ok, text} ->
          {:ok,
           "## Argus #{project} ##{id}\n\n" <>
             untrusted(text, "argus", project: project, issue: id)}

        {:error, :not_found} ->
          {:error, "Argus has no issue #{id} in #{project}, or you can't see it."}

        {:error, reason} ->
          {:error, problem(:argus, reason)}
      end
    end
  end
end
