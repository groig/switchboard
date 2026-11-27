defmodule Switchboard.Tools.ErrorResolve do
  @moduledoc "Marks an Argus issue as resolved, as the person."
  use Switchboard.Tools.Support

  alias Switchboard.Tools.ArgusStatus

  @impl true
  def name, do: "error_resolve"
  @impl true
  def title, do: "Resolve an Argus error"
  @impl true
  def description,
    do:
      "Marks an Argus issue as resolved, as you. It reopens automatically if the error happens " <>
        "again, so resolve only after the fix is deployed. This writes to Argus: before calling " <>
        "it, show the user the issue (project, id, title) and get their explicit OK (confirm first)."

  @impl true
  def input_schema, do: ArgusStatus.schema()
  @impl true
  def annotations, do: %{read_only: false, destructive: false, idempotent: true, open_world: true}
  @impl true
  def connections, do: [:argus]

  @impl true
  def aliases, do: %{"issue" => "id", "issue_id" => "id", "project_slug" => "project"}

  @impl true
  def example do
    %{
      args: %{"project" => "demo-api", "id" => "7"},
      output: "Argus demo-api #7 is now **resolved** (as you)."
    }
  end

  @impl true
  def call(scope, args), do: ArgusStatus.run(scope, args, :resolve)
end
