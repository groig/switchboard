defmodule Switchboard.ToolsDocTest do
  use ExUnit.Case, async: true

  test "docs/TOOLS.md is up to date (run `mix switchboard.gen.tools_doc`)" do
    assert File.read!(Switchboard.Tools.Doc.path()) == Switchboard.Tools.Doc.render()
  end

  # Watches change only Switchboard's own state for the caller: they say so instead.
  test "every write tool tells the agent to confirm first, or that it only affects the caller" do
    for mod <- Switchboard.Tools.all(), not mod.annotations()[:read_only] do
      assert mod.description() =~ ~r/confirm|only (notifies|affects) the user who asked/i,
             "#{mod.name()} must ask for confirmation"
    end
  end
end
