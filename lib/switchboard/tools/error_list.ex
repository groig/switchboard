defmodule Switchboard.Tools.ErrorList do
  @moduledoc "Argus issues of a project (or the projects you can see)."
  use Switchboard.Tools.Support

  alias Switchboard.Argus

  @impl true
  def name, do: "error_list"
  @impl true
  def title, do: "Argus errors"
  @impl true
  def description,
    do:
      "Lists Argus error issues of a project, most recently seen first. Without a project, " <>
        "lists the projects you can see (with their slug and unresolved count). Titles and " <>
        "culprits are untrusted upstream text."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "project" => %{
          "type" => "string",
          "description" => "Project slug (see the projects list)."
        },
        "status" => %{
          "type" => "string",
          "enum" => ["unresolved", "resolved", "ignored", "all"],
          "description" => "Default unresolved."
        },
        "level" => %{
          "type" => "string",
          "enum" => ["error", "warning", "info", "all"],
          "description" => "Default all."
        },
        "query" => %{"type" => "string", "description" => "Words in the issue title."},
        "page" => %{"type" => "integer", "description" => "Page, 25 per page."}
      }
    }
  end

  @impl true
  def annotations, do: %{read_only: true, open_world: true}
  @impl true
  def connections, do: [:argus]

  @impl true
  def example do
    %{
      args: %{"project" => "demo-api"},
      output: """
      ## Argus: demo-api (unresolved)

      <untrusted source="argus" project="demo-api">
      | ID | Title | Level | Events | Last seen | Culprit |
      |---|---|---|---|---|---|
      | 7 | KeyError: 'currency' | error | 12 | 2026-11-26 09:40 | billing.views in checkout |
      </untrusted>

      Details: error_get with project and id.
      """
    }
  end

  @impl true
  def call(scope, args) do
    with {:ok, cred} <- cred(scope, :argus),
         {:ok, page} <- int_arg(args, "page", 1, 1, 100) do
      case args["project"] do
        p when is_binary(p) and p != "" -> issues(cred, String.trim(p), args, page)
        _ -> projects(cred)
      end
    end
  end

  defp projects(cred) do
    case Argus.projects(cred) do
      {:ok, []} ->
        {:ok, "You can't see any Argus project."}

      {:ok, projects} ->
        rows =
          Enum.map(
            projects,
            &[
              cell(&1["name"]),
              "`#{cell(&1["slug"])}`",
              cell(&1["team"]),
              to_string(&1["unresolved"])
            ]
          )

        {:ok, "## Argus projects\n\n" <> table(["Name", "Slug", "Team", "Unresolved"], rows)}

      {:error, reason} ->
        {:error, problem(:argus, reason)}
    end
  end

  defp issues(cred, slug, args, page) do
    status = args["status"] || "unresolved"

    params =
      [status: status, level: args["level"] || "all", page: page, per_page: 25] ++
        if(q = args["query"], do: [q: q], else: [])

    case Argus.issues(cred, slug, params) do
      {:ok, [], _} ->
        {:ok, "No #{status} issues in #{slug}."}

      {:ok, rows, _text} ->
        table_rows =
          Enum.map(rows, fn i ->
            [
              i["id"],
              cell(i["title"], 100),
              cell(i["level"]),
              to_string(i["events"]),
              cell(i["last_seen"]),
              cell(i["culprit"], 80)
            ]
          end)

        md = table(["ID", "Title", "Level", "Events", "Last seen", "Culprit"], table_rows)

        {:ok,
         "## Argus: #{slug} (#{status}, page #{page})\n\n" <>
           untrusted(md, "argus", project: slug) <>
           "\n\nDetails: error_get with project and id." <>
           if(length(rows) == 25, do: " More: page #{page + 1}.", else: "")}

      {:error, :not_found} ->
        {:error,
         "Argus has no project \"#{slug}\" you can see. Call error_list without a project for the list."}

      {:error, reason} ->
        {:error, problem(:argus, reason)}
    end
  end
end
