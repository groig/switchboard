defmodule Switchboard.Tools.Release do
  @moduledoc "A production release: what shipped, tasks, health and new errors."
  use Switchboard.Tools.Support

  alias Switchboard.Releases
  alias Switchboard.Tools.ReleaseRender

  @impl true
  def name, do: "release"
  @impl true
  def title, do: "Production release"
  @impl true
  def description,
    do:
      "Shows a production release (from the release bot's release cards): status, highlights, the " <>
        "Plane tasks it shipped, health and the Argus errors that followed. By name, or the " <>
        "latest of a repo; without arguments, the latest release of each repo."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "repo" => %{
          "type" => "string",
          "description" => "Repository name as in the release cards, e.g. web."
        },
        "name" => %{
          "type" => "string",
          "description" => "Release name (branch), or \"latest\" (default)."
        }
      }
    }
  end

  @impl true
  def annotations, do: %{read_only: true, open_world: true}
  @impl true
  def connections, do: []

  @impl true
  def example do
    %{
      args: %{"repo" => "demo", "name" => "latest"},
      output: """
      ## demo release-demo.3

      | | |
      |---|---|
      | Status | 🚀 success |
      | Started | 2026-11-26 10:02 (Europe/Madrid) |
      | Health | 🟡 yellow (watching the first 24 h) |

      ### Highlights

      <untrusted source="releases">
      - Invoices can be exported as CSV (DEMO-12)
      </untrusted>

      ### Tasks

      | Task | How | Link |
      |---|---|---|
      | DEMO-12 | named in a commit | https://projects.example.com/demo/browse/DEMO-12/ |
      """
    }
  end

  @impl true
  def call(scope, args) do
    repo = blank(args["repo"])
    name = blank(args["name"]) || "latest"

    result =
      cond do
        name != "latest" -> Releases.find(name, repo) |> map_ok(&ReleaseRender.card(&1, scope))
        repo -> Releases.latest(repo) |> map_ok(&ReleaseRender.card(&1, scope))
        true -> latest_per_repo(scope)
      end

    case result do
      {:ok, md} ->
        {:ok, Markdown.cap(md)}

      {:error, :not_found} ->
        {:error,
         "No release #{if name != "latest", do: name, else: "of #{repo}"} in the last 90 days."}

      {:error, reason} ->
        {:error, problem(:releases, reason)}
    end
  end

  defp latest_per_repo(scope) do
    with {:ok, releases} <- Releases.list(limit: 100) do
      rows =
        releases
        |> Enum.uniq_by(& &1["repo"])
        |> Enum.map(fn r ->
          [
            cell(r["repo"]),
            cell(r["name"]),
            ReleaseRender.status(r),
            time(r["startedAt"], scope),
            ReleaseRender.health(r)
          ]
        end)

      if rows == [],
        do: {:ok, "No releases in the last 90 days."},
        else:
          {:ok,
           "## Latest releases\n\n" <>
             table(["Repo", "Release", "Status", "Started", "Health"], rows)}
    end
  end

  defp map_ok({:ok, v}, f), do: {:ok, f.(v)}
  defp map_ok(error, _f), do: error

  defp blank(nil), do: nil
  defp blank(s), do: if(String.trim(s) == "", do: nil, else: String.trim(s))
end
