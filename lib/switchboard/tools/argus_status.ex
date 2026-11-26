defmodule Switchboard.Tools.ArgusStatus do
  @moduledoc "Shared implementation of error_resolve and error_ignore."
  import Switchboard.Tools.Support

  alias Switchboard.Argus

  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "project" => %{"type" => "string", "description" => "Project slug."},
        "id" => %{"type" => "string", "description" => "Issue id."}
      },
      "required" => ["project", "id"]
    }
  end

  def run(scope, %{"project" => project, "id" => id}, action) do
    project = String.trim(project)

    with true <- id =~ ~r/^\w{1,40}$/ || {:error, "id looks wrong"},
         true <- project =~ ~r/^[\w.\-]{1,100}$/ || {:error, "project looks wrong"},
         {:ok, cred} <- cred(scope, :argus) do
      case Argus.change_status(cred, project, id, action) do
        {:ok, text} ->
          done = if action == :resolve, do: "resolved", else: "ignored"

          {:ok,
           "Argus #{project} ##{id} is now **#{done}** (as you).\n\n" <>
             untrusted(String.trim(to_string(text)), "argus", project: project, issue: id)}

        {:error, :not_found} ->
          {:error, "Argus has no issue #{id} in #{project}, or you can't see it."}

        {:error, reason} ->
          {:error, problem(:argus, reason)}
      end
    end
  end
end
