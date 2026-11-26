defmodule Switchboard.ToolsDocTest do
  use ExUnit.Case, async: true

  test "docs/TOOLS.md is up to date (run `mix switchboard.gen.tools_doc`)" do
    assert File.read!(Switchboard.Tools.Doc.path()) == Switchboard.Tools.Doc.render()
  end

  test "every write tool tells the agent to confirm first" do
    for mod <- Switchboard.Tools.all(), not mod.annotations()[:read_only] do
      assert mod.description() =~ ~r/confirm/i, "#{mod.name()} must ask for confirmation"
    end
  end
end
