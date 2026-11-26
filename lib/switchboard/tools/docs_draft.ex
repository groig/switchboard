defmodule Switchboard.Tools.DocsDraft do
  @moduledoc "Creates a draft in the person's Outline account. Never publishes."
  use Switchboard.Tools.Support

  alias Switchboard.Outline

  @max_text 100_000

  @impl true
  def name, do: "docs_draft"
  @impl true
  def title, do: "Draft a wiki document"
  @impl true
  def description,
    do:
      "Creates a draft document (Markdown) in your Outline account. It is never published: you " <>
        "review and publish it yourself in Outline. This writes to Outline: before calling it, " <>
        "show the user the title and text and get their explicit OK (confirm first)."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string", "description" => "Up to 100 characters."},
        "text" => %{"type" => "string", "description" => "The body, in Markdown."},
        "collection_id" => %{
          "type" => "string",
          "description" => "Optional collection UUID for when it is published."
        }
      },
      "required" => ["title", "text"]
    }
  end

  @impl true
  def annotations,
    do: %{read_only: false, destructive: false, idempotent: false, open_world: true}

  @impl true
  def connections, do: [:outline]

  @impl true
  def example do
    %{
      args: %{"title" => "QA handoff: DEMO-12", "text" => "## What changed\n..."},
      output:
        "Draft created in your Outline account (not published): **QA handoff: DEMO-12** https://docs.example.com/doc/qa-handoff-demo-12-a1B2c3D4e5"
    }
  end

  defp valid_collection(nil), do: :ok

  defp valid_collection(id) do
    if id =~ ~r/^[0-9a-f-]{36}$/, do: :ok, else: {:error, "collection_id must be a UUID"}
  end

  @impl true
  def call(scope, %{"title" => title, "text" => text} = args) do
    title = String.trim(title)
    collection = args["collection_id"]

    with true <- title != "" || {:error, "title must not be empty"},
         true <- String.length(title) <= 100 || {:error, "title is longer than 100 characters"},
         true <-
           String.length(text) <= @max_text ||
             {:error, "text is longer than #{@max_text} characters"},
         :ok <- valid_collection(collection),
         {:ok, cred} <- cred(scope, :outline) do
      case Outline.create_draft(cred, title, text, collection) do
        {:ok, doc} ->
          {:ok,
           "Draft created in your Outline account (not published): **#{cell(doc["title"], 100)}** #{doc["url"]}"}

        {:error, :published} ->
          {:error,
           "Outline published the document instead of keeping it as a draft. Check it in Outline."}

        {:error, reason} ->
          {:error, problem(:outline, reason)}
      end
    end
  end
end
