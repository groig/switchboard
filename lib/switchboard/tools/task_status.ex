defmodule Switchboard.Tools.TaskStatus do
  @moduledoc """
  The whole story of a work item across systems: the Plane item, the PRs and commits that
  mention it with their CI, the release that shipped it, and the errors after that release.
  """
  use Switchboard.Tools.Support

  alias Switchboard.{FanOut, Forgejo, Plane, Releases}
  alias Switchboard.Tools.{ForgejoRender, ReleaseRender}

  @max_prs 4

  @impl true
  def name, do: "task_status"
  @impl true
  def title, do: "Task status across systems"
  @impl true
  def description,
    do:
      "The whole story of a work item (e.g. PROJ-123): its Plane state, the pull requests " <>
        "and commits that mention it with their CI status, the production release that shipped " <>
        "it (or \"not in production yet\"), and the Argus errors after that release. Systems " <>
        "that are not connected or not answering are skipped with a note."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "id" => %{"type" => "string", "description" => "Work item identifier, e.g. PROJ-123."}
      },
      "required" => ["id"]
    }
  end

  @impl true
  def annotations, do: %{read_only: true, open_world: true}
  @impl true
  def connections, do: [:plane, :forgejo]

  @impl true
  def example do
    %{
      args: %{"id" => "DEMO-12"},
      output: """
      ## DEMO-12: Export invoices as CSV

      **Plane:** Done (completed) · priority high · ana · https://projects.example.com/demo/browse/DEMO-12/

      ### Pull requests

      | PR | State | CI | Reviews |
      |---|---|---|---|
      | [demo/app#42](https://git.example.com/demo/app/pulls/42) | merged | ✅ success | bruno: approved |

      Commits naming it: `4f2c9e1a3b` (demo/app#42)

      ### Production

      🚀 Shipped in **demo release-demo.3** on 2026-11-26 10:02 (Europe/Madrid), named in a commit. Health: 🟡 yellow (watching the first 24 h).

      ### Errors after the release

      <untrusted source="argus">
      | ID | Title | From this release | Link |
      |---|---|---|---|
      | 7 | KeyError: 'currency' | no | https://bugs.example.com/demo/issues/7 |
      </untrusted>
      """
    }
  end

  @impl true
  def call(scope, %{"id" => id}) do
    id = id |> String.trim() |> String.upcase()

    if Plane.identifier?(id) do
      results =
        FanOut.run(
          [
            {:plane, :plane, fn -> plane(scope, id) end},
            {:prs, :forgejo, fn -> prs(scope, id) end},
            {:releases, :releases, fn -> Releases.list(limit: 200) end}
          ],
          timeout: 9_000
        )

      {:ok, render(scope, id, results) |> Markdown.cap()}
    else
      {:error, "id must look like PROJECT-123"}
    end
  end

  defp plane(scope, id) do
    with {:ok, cred} <- Switchboard.Upstreams.credential(scope, :plane) do
      Plane.item(cred, id)
    end
  end

  # PRs whose title or body names the task, newest first, each with CI and the commits naming it.
  defp prs(scope, id) do
    with {:ok, found} <- Forgejo.search_prs(scope, q: id, state: "all", limit: 20) do
      pattern = ~r/\b#{Regex.escape(id)}\b/i

      found
      |> Enum.filter(&((&1["title"] || "") =~ pattern or (&1["body"] || "") =~ pattern))
      |> Enum.take(@max_prs)
      |> Task.async_stream(&pr_detail(scope, &1, pattern), timeout: 8_000, on_timeout: :kill_task)
      |> Enum.flat_map(fn
        {:ok, detail} -> [detail]
        _ -> []
      end)
      |> then(&{:ok, &1})
    end
  end

  defp pr_detail(scope, issue, pattern) do
    full = get_in(issue, ["repository", "full_name"]) || ""
    {:ok, owner, repo} = Forgejo.parse_repo(full)

    with {:ok, pr} <- Forgejo.pull(scope, owner, repo, issue["number"]) do
      sha = get_in(pr, ["head", "sha"])

      status =
        case Forgejo.status(scope, owner, repo, sha) do
          {:ok, s} -> ForgejoRender.check_state(s["state"])
          _ -> "–"
        end

      reviews =
        case Forgejo.reviews(scope, owner, repo, pr["number"]) do
          {:ok, r} -> ForgejoRender.reviews_summary(r, pr["requested_reviewers"])
          _ -> "–"
        end

      commits =
        case Forgejo.pull_commits(scope, owner, repo, pr["number"]) do
          {:ok, list} ->
            for c <- list, (get_in(c, ["commit", "message"]) || "") =~ pattern, do: c["sha"]

          _ ->
            []
        end

      %{repo: full, pr: pr, ci: status, reviews: reviews, commits: commits}
    else
      _ -> %{repo: full, pr: issue, ci: "–", reviews: "–", commits: []}
    end
  end

  defp render(scope, id, results) do
    {head, notes} = plane_section(id, results.plane)
    {pr_md, pr_notes} = pr_section(results.prs)
    {prod_md, errors_md, rel_notes} = release_section(scope, id, results.releases)

    """
    #{head}

    ### Pull requests

    #{pr_md}

    ### Production

    #{prod_md}
    #{if errors_md, do: "\n### Errors after the release\n\n" <> errors_md, else: ""}\
    """
    |> String.trim_trailing()
    |> with_notes(notes ++ pr_notes ++ rel_notes)
  end

  defp plane_section(id, {:ok, item}) do
    state = item["state"] || %{}
    who = Enum.map_join(item["assignees"] || [], ", ", &(&1["display_name"] || "?"))

    {"## #{id}: #{cell(item["name"], 200)}\n\n**Plane:** #{cell(state["name"])} (#{state["group"] || "?"}) · priority #{cell(item["priority"])} · #{cell(who)} · #{Plane.browse_url(id)}",
     []}
  end

  defp plane_section(id, {:error, :not_found}),
    do: {"## #{id}", ["Plane has no work item #{id}, or you can't see it."]}

  defp plane_section(id, {:error, reason}), do: {"## #{id}", [problem(:plane, reason)]}

  defp pr_section({:ok, []}), do: {"No pull request mentions it.", []}

  defp pr_section({:ok, prs}) do
    rows =
      Enum.map(prs, fn %{repo: repo, pr: pr, ci: ci, reviews: reviews} ->
        [
          "[#{repo}##{pr["number"]}](#{pr["html_url"]})",
          ForgejoRender.pr_state(pr),
          ci,
          cell(reviews, 120)
        ]
      end)

    commits =
      for %{repo: repo, pr: pr, commits: shas} <- prs,
          sha <- shas,
          do: "`#{String.slice(sha, 0, 10)}` (#{repo}##{pr["number"]})"

    commits_md =
      if commits == [],
        do: "",
        else: "\n\nCommits naming it: " <> Enum.join(Enum.uniq(commits), ", ")

    {table(["PR", "State", "CI", "Reviews"], rows) <> commits_md, []}
  end

  defp pr_section({:error, reason}), do: {"–", [problem(:forgejo, reason)]}

  defp release_section(scope, id, {:ok, releases}) do
    case Releases.shipping(id, releases) |> List.last() do
      nil ->
        {"Not in production yet (no successful release in the last 90 days names #{id}).", nil,
         []}

      first ->
        task = Enum.find(first["tasks"] || [], &(String.upcase(&1["id"] || "") == id)) || %{}

        how =
          if task["match"] == "matched", do: "matched from the changes", else: "named in a commit"

        {"🚀 Shipped in **#{first["repo"]} #{first["name"]}** on #{time(first["finishedAt"] || first["startedAt"], scope)}, #{how}. Health: #{ReleaseRender.health(first)}. Card: #{first["cardUrl"] || "–"}",
         ReleaseRender.issues(first), []}
    end
  end

  defp release_section(_scope, _id, {:error, reason}),
    do: {"Unknown.", nil, [problem(:releases, reason)]}
end
