defmodule Switchboard.Tools.PlaneComment do
  @moduledoc "Adds a comment to a Plane work item, as the person."
  use Switchboard.Tools.Support

  alias Switchboard.Plane

  @max 5_000

  @impl true
  def name, do: "plane_comment"
  @impl true
  def title, do: "Comment on a Plane item"
  @impl true
  def description,
    do:
      "Adds a comment to a Plane work item as you, with your own Plane key. This writes to " <>
        "Plane: before calling it, show the user the exact comment and the item, and get their " <>
        "explicit OK (confirm first). Plain text, up to #{@max} characters."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "id" => %{"type" => "string", "description" => "Work item identifier, e.g. PROJ-123."},
        "text" => %{"type" => "string", "description" => "The comment, plain text."}
      },
      "required" => ["id", "text"]
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
      args: %{"id" => "DEMO-12", "text" => "Deployed to staging, ready for QA."},
      output:
        "Commented on DEMO-12 (Export invoices as CSV) as you: https://projects.example.com/demo/browse/DEMO-12/"
    }
  end

  @impl true
  def call(scope, %{"id" => id, "text" => text}) do
    id = id |> String.trim() |> String.upcase()
    text = String.trim(text)

    with true <- Plane.identifier?(id) || {:error, "id must look like PROJECT-123"},
         true <- text != "" || {:error, "text must not be empty"},
         true <- String.length(text) <= @max || {:error, "text is longer than #{@max} characters"},
         {:ok, cred} <- cred(scope, :plane),
         {:ok, item} <- Plane.fresh_item(cred, id) |> not_found(id),
         {:ok, _comment} <- Plane.comment(cred, item, text) |> plane_error() do
      {:ok, "Commented on #{id} (#{cell(item["name"], 100)}) as you: #{Plane.browse_url(id)}"}
    end
  end

  defp not_found({:error, :not_found}, id),
    do: {:error, "Plane has no work item #{id}, or you can't see it."}

  defp not_found(other, _id), do: plane_error(other)

  defp plane_error({:error, reason}), do: {:error, problem(:plane, reason)}
  defp plane_error(ok), do: ok
end
