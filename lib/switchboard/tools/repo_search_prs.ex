defmodule Switchboard.Tools.RepoSearchPrs do
  @moduledoc "Search pull requests on Forgejo and GitHub."
  use Switchboard.Tools.Support

  alias Switchboard.{Forgejo, GitHub, Repos}
  alias Switchboard.Repos.Ref

  @impl true
  def name, do: "repo_search_prs"
  @impl true
  def title, do: "Search pull requests"
  @impl true
  def description,
    do:
      "Searches pull requests you can see: by text (e.g. a task id like PROJ-123), " <>
        "repository, state, and whether you created them or your review was requested. " <>
        "Without repo it searches Forgejo, and GitHub's configured organizations when you " <>
        "connected GitHub."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string", "description" => "Text in the title or description."},
        "repo" => %{
          "type" => "string",
          "description" => "Only this repository. " <> Repos.schema_description()
        },
        "state" => %{
          "type" => "string",
          "enum" => ["open", "closed", "all"],
          "description" => "Default open."
        },
        "mine" => %{
          "type" => "string",
          "enum" => ["created", "review_requested", "assigned"],
          "description" => "Only PRs you created, are asked to review, or are assigned."
        }
      }
    }
  end

  @impl true
  def annotations, do: %{read_only: true, open_world: true}
  @impl true
  def connections, do: [:forgejo, :github]

  @impl true
  def aliases,
    do: %{"repository" => "repo", "q" => "query", "text" => "query", "search" => "query"}

  @impl true
  def example do
    %{
      args: %{"query" => "DEMO-12", "state" => "all"},
      output: """
      ## Pull requests: "DEMO-12" (all)

      | PR | Title | Author | State | Updated |
      |---|---|---|---|---|
      | [demo/app#42](https://git.example.com/demo/app/pulls/42) | DEMO-12 Export invoices as CSV | ana | open | 2026-11-26 |
      """
    }
  end

  @impl true
  def call(scope, args) do
    state = args["state"] || "open"

    params =
      [state: state, limit: 25, sort: "recentupdate"] ++
        if(q = blank(args["query"]), do: [q: q], else: []) ++
        case args["mine"] do
          "created" -> [created: true]
          "review_requested" -> [review_requested: true]
          "assigned" -> [assigned: true]
          _ -> []
        end

    case blank(args["repo"]) do
      nil ->
        case Repos.search_all(scope, params) do
          {:ok, prs, notes} -> {:ok, render(prs, args, state) |> with_notes(notes)}
          {:error, line} when is_binary(line) -> {:error, line}
          {:error, reason} -> {:error, problem(:forgejo, reason)}
        end

      repo ->
        with {:ok, ref} <- Repos.resolve(repo) do
          case in_repo(scope, ref, params) do
            {:ok, prs} -> {:ok, render(prs, args, state)}
            {:error, reason} -> {:error, Repos.problem(ref, reason)}
          end
        end
    end
  end

  defp in_repo(scope, %Ref{host: :github} = ref, params),
    do: GitHub.search_prs(scope, Keyword.put(params, :repo, Ref.full(ref)))

  defp in_repo(scope, %Ref{} = ref, params) do
    with {:ok, prs} <- Forgejo.search_prs(scope, Keyword.put(params, :owner, ref.owner)) do
      full = String.downcase(Ref.full(ref))

      {:ok,
       Enum.filter(
         prs,
         &(String.downcase(get_in(&1, ["repository", "full_name"]) || "") == full)
       )}
    end
  end

  defp blank(nil), do: nil
  defp blank(s), do: if(String.trim(s) == "", do: nil, else: String.trim(s))

  defp render([], _args, _state), do: "No pull requests match."

  defp render(prs, args, state) do
    rows =
      Enum.map(prs, fn pr ->
        repo = get_in(pr, ["repository", "full_name"]) || "?"
        pr_state = if pr["pull_request"]["merged"], do: "merged", else: pr["state"]

        [
          "[#{repo}##{pr["number"]}](#{pr["html_url"]})",
          cell(pr["title"], 90),
          cell(get_in(pr, ["user", "login"])),
          cell(pr_state),
          Markdown.date(pr["updated_at"])
        ]
      end)

    label = if q = args["query"], do: " \"#{cell(q)}\"", else: ""

    "## Pull requests#{label} (#{state})\n\n" <>
      table(["PR", "Title", "Author", "State", "Updated"], rows)
  end
end
