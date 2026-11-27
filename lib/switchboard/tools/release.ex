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
        "latest of a repo; without arguments, the latest release of each repo. The repo may be " <>
        "owner/name, the short name or a unique prefix. When nothing matches, it lists the repos " <>
        "that publish releases and suggests close release names. Only repos whose deploy " <>
        "pipeline publishes to the release feed have releases here."

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
      with {:ok, all} <- Releases.list(limit: 200) do
        if is_nil(repo) and name == "latest",
          do: latest_per_repo(all, scope),
          else: lookup(all, repo, name, scope)
      end

    case result do
      {:ok, md} -> {:ok, Markdown.cap(md)}
      {:miss, md} -> {:error, Markdown.cap(md)}
      {:error, reason} -> {:error, problem(:releases, reason)}
    end
  end

  # A repo given: resolve it (owner/name, case, unique prefix), then the release in it.
  defp lookup(all, repo_in, name, scope) when is_binary(repo_in) do
    case Releases.resolve_repo(all, repo_in) do
      {:ok, repo} ->
        in_repo(all, repo, name, scope)

      {:ambiguous, repos} ->
        {:miss,
         "\"#{cell(repo_in)}\" matches several repos with releases: " <>
           Enum.map_join(repos, ", ", &"`#{&1}`") <> ". Call again with one of them."}

      :unknown ->
        # Not among the newest 200: ask the feed for the repo itself before giving up.
        case Releases.latest(repo_in) do
          {:ok, %{"repo" => ^repo_in}} -> in_repo(all, repo_in, name, scope)
          {:error, reason} when reason != :not_found -> {:error, reason}
          _ -> unknown_repo(all, repo_in, scope)
        end
    end
  end

  # Only a name: the release, or a repo given as the name, or suggestions.
  defp lookup(all, nil, name, scope) do
    case Enum.find(all, &(&1["name"] == name)) || found(Releases.find(name)) do
      %{} = r ->
        {:ok, ReleaseRender.card(r, scope)}

      nil ->
        case Releases.resolve_repo(all, name) do
          {:ok, repo} ->
            {:ok,
             "`#{cell(name)}` is a repo, not a release name; its latest release:\n\n" <>
               ReleaseRender.card(newest(all, repo), scope)}

          _ ->
            no_name(all, name, nil, scope)
        end
    end
  end

  defp in_repo(all, repo, "latest", scope) do
    case newest(all, repo) || found(Releases.latest(repo)) do
      nil -> unknown_repo(all, repo, scope)
      r -> {:ok, ReleaseRender.card(r, scope)}
    end
  end

  defp in_repo(all, repo, name, scope) do
    mine = Enum.filter(all, &(&1["repo"] == repo))

    case Enum.find(mine, &(&1["name"] == name)) || found(Releases.find(name, repo)) do
      %{"repo" => ^repo} = r -> {:ok, ReleaseRender.card(r, scope)}
      _ -> no_name(mine, name, repo, scope)
    end
  end

  defp newest(all, repo), do: Enum.find(all, &(&1["repo"] == repo))

  defp found({:ok, r}), do: r
  defp found(_), do: nil

  defp unknown_repo(all, repo_in, scope) do
    guesses = Releases.suggest_names(all, repo_in)

    lead =
      case guesses do
        [] ->
          "No release of `#{cell(repo_in)}` in the last 90 days."

        _ ->
          "`#{cell(repo_in)}` is not a repo with releases. Did you mean the release " <>
            Enum.map_join(guesses, " or ", &"`#{&1}`") <> "? (Pass it as `name`.)"
      end

    {:miss, lead <> "\n\n" <> ReleaseRender.feed_hint(all, scope)}
  end

  defp no_name(releases, name, repo, scope) do
    where = if repo, do: " of `#{repo}`", else: ""

    lead =
      case Releases.suggest_names(releases, name) do
        [] ->
          "No release named `#{cell(name)}`#{where} in the last 90 days."

        guesses ->
          "No release named `#{cell(name)}`#{where} in the last 90 days. Did you mean " <>
            Enum.map_join(guesses, " or ", &"`#{&1}`") <> "?"
      end

    recent =
      case releases |> Enum.take(5) |> Enum.map(& &1["name"]) do
        [] ->
          ""

        names when not is_nil(repo) ->
          "\n\nLatest releases#{where}: " <> Enum.map_join(names, ", ", &"`#{&1}`") <> "."

        _ ->
          ""
      end

    hint = if repo, do: "", else: "\n\n" <> ReleaseRender.feed_hint(releases, scope)
    {:miss, lead <> recent <> hint}
  end

  defp latest_per_repo(releases, scope) do
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

  defp blank(nil), do: nil
  defp blank(s), do: if(String.trim(s) == "", do: nil, else: String.trim(s))
end
