defmodule Switchboard.Tools.DocsSearch do
  @moduledoc "Search the Outline wiki."
  use Switchboard.Tools.Support

  alias Switchboard.Outline

  @impl true
  def name, do: "docs_search"
  @impl true
  def title, do: "Search the wiki"
  @impl true
  def description,
    do:
      "Full-text search in the Outline wiki with your own access. " <>
        "Returns titles, links and a snippet; read a document with docs_read."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string"},
        "limit" => %{"type" => "integer", "description" => "1-20, default 8."}
      },
      "required" => ["query"]
    }
  end

  @impl true
  def annotations, do: %{read_only: true, open_world: true}
  @impl true
  def connections, do: [:outline]

  @impl true
  def example do
    %{
      args: %{"query" => "deploy checklist"},
      output: """
      ## Wiki: "deploy checklist"

      1. **Production deploy checklist** (id `a1B2c3D4e5`, updated 2026-11-02)
         https://docs.example.com/doc/production-deploy-checklist-a1B2c3D4e5
         <untrusted source="outline" doc="a1B2c3D4e5">
         Before a release: run the migrations dry-run, check the...
         </untrusted>
      """
    }
  end

  @impl true
  def call(scope, %{"query" => query} = args) do
    with {:ok, limit} <- int_arg(args, "limit", 8, 1, 20),
         true <- String.trim(query) != "" || {:error, "query must not be empty"},
         {:ok, cred} <- cred(scope, :outline) do
      case Outline.search(cred, String.trim(query), limit: limit) do
        {:ok, []} ->
          {:ok, "Nothing in the wiki matches \"#{cell(query)}\"."}

        {:ok, hits} ->
          items =
            hits
            |> Enum.with_index(1)
            |> Enum.map_join("\n", fn {h, i} ->
              snippet = Markdown.html_to_text(h["context"]) |> Markdown.truncate(300)

              "#{i}. **#{cell(h["title"], 120)}** (id `#{h["url_id"]}`, updated #{Markdown.date(h["updated_at"])})\n" <>
                "   #{h["url"]}\n" <>
                (untrusted(snippet, "outline", doc: h["url_id"])
                 |> String.replace("\n", "\n   ")
                 |> then(&("   " <> &1)))
            end)

          {:ok, "## Wiki: \"#{cell(query)}\"\n\n" <> items}

        {:error, reason} ->
          {:error, problem(:outline, reason)}
      end
    end
  end
end
