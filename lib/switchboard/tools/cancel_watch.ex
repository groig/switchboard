defmodule Switchboard.Tools.CancelWatch do
  @moduledoc "Cancels one of the caller's own watches."
  use Switchboard.Tools.Support

  alias Switchboard.Watches
  alias Switchboard.Watches.Watch

  @impl true
  def name, do: "cancel_watch"
  @impl true
  def title, do: "Cancel a watch"
  @impl true
  def description,
    do:
      "Use when the user wants to stop a watch. Cancels one of their own watches by id (from " <>
        "list_watches); no notice is sent. It only affects the user who asked."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{"id" => %{"type" => "string", "description" => "Watch id."}},
      "required" => ["id"]
    }
  end

  @impl true
  def annotations,
    do: %{read_only: false, destructive: false, idempotent: true, open_world: false}

  @impl true
  def connections, do: []

  @impl true
  def aliases, do: %{"watch_id" => "id"}

  @impl true
  def example do
    %{
      args: %{"id" => "5b1c0d2e-7f3a-4c51-9e0b-2a6d8c4f1e37"},
      output: "Cancelled your watch on demo/app#42."
    }
  end

  @impl true
  def call(scope, %{"id" => id}) do
    case Watches.cancel(scope, String.trim(id)) do
      {:ok, watch} -> {:ok, "Cancelled your watch on #{Watch.label(watch)}."}
      {:error, :not_found} -> {:error, "You have no watch with id #{id} (see list_watches)."}
      {:error, :not_active} -> {:error, "That watch already ended."}
    end
  end
end
