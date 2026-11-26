defmodule Switchboard.TestTools.Note do
  @moduledoc "A write tool used only by tests: echoes its text. Flags `secret` as sensitive."
  @behaviour Switchboard.Tool

  @impl true
  def name, do: "test_note"
  @impl true
  def title, do: "Test note"
  @impl true
  def description, do: "Writes a note (test only). Confirm with the user first."
  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{"text" => %{"type" => "string"}, "secret" => %{"type" => "string"}},
      "required" => ["text"]
    }
  end

  @impl true
  def annotations, do: %{read_only: false, destructive: false, idempotent: false}
  @impl true
  def connections, do: []
  @impl true
  def sensitive_args, do: ["text"]

  @impl true
  def call(_scope, %{"text" => "crash"}), do: raise("boom")

  def call(_scope, %{"text" => text}) do
    Switchboard.Tools.note_upstream(:plane)
    {:ok, "noted: #{text}"}
  end
end
