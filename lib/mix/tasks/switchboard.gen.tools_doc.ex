defmodule Mix.Tasks.Switchboard.Gen.ToolsDoc do
  @shortdoc "Regenerates docs/TOOLS.md from the tool registry"
  @moduledoc """
  Regenerates `docs/TOOLS.md` from `Switchboard.Tools`. A test fails when the file is stale,
  so run this after adding or changing a tool:

      mix switchboard.gen.tools_doc
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("compile")
    File.write!(Switchboard.Tools.Doc.path(), Switchboard.Tools.Doc.render())
    Mix.shell().info("Wrote #{Switchboard.Tools.Doc.path()}")
  end
end
