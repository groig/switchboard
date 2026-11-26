defmodule Switchboard.Tools.ErrorIgnore do
  @moduledoc "Marks an Argus issue as ignored, as the person."
  use Switchboard.Tools.Support

  alias Switchboard.Tools.ArgusStatus

  @impl true
  def name, do: "error_ignore"
  @impl true
  def title, do: "Ignore an Argus error"
  @impl true
  def description,
    do:
      "Marks an Argus issue as ignored, as you. Use it only for errors that need no fix " <>
        "(expected or harmless); it stays ignored when new events arrive. For fixed errors use " <>
        "error_resolve. This writes to Argus: before calling it, show the user the issue and why " <>
        "it needs no fix, and get their explicit OK (confirm first)."

  @impl true
  def input_schema, do: ArgusStatus.schema()
  @impl true
  def annotations, do: %{read_only: false, destructive: false, idempotent: true, open_world: true}
  @impl true
  def connections, do: [:argus]

  @impl true
  def example do
    %{
      args: %{"project" => "demo-api", "id" => "8"},
      output: "Argus demo-api #8 is now **ignored** (as you)."
    }
  end

  @impl true
  def call(scope, args), do: ArgusStatus.run(scope, args, :ignore)
end
