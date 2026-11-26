defmodule Switchboard.Tools.MyWork do
  @moduledoc """
  One view of the caller's day across systems, fetched concurrently: Plane items, open PRs
  with CI, recent Argus errors (flagged when the culprit matches files of their recent
  commits), and what of theirs shipped. Each system is optional; a slow or failing one becomes
  a note and the rest still render.
  """
  use Switchboard.Tools.Support

  alias Switchboard.{FanOut, Forgejo, Plane, Releases, Upstreams}
  alias Switchboard.Tools.{ForgejoRender, PlaneMyItems, ReleaseRender}

  @max_prs 6
  @max_error_projects 6
  @budget 9_000

  @impl true
  def name, do: "my_work"
  @impl true
  def title, do: "My work"
  @impl true
  def description,
    do:
      "One view of your day across systems: Plane items assigned to you (urgent and due first), " <>
        "your open pull requests and review requests with CI status, recent unresolved Argus " <>
        "errors (flagged when they point at files you changed recently), and what of yours " <>
        "shipped to production in the last 7 days. Use it for \"what's on my plate?\"."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "scope" => %{
          "type" => "string",
          "enum" => ["today", "week"],
          "description" =>
            "Window for errors and your commits: today (24 h, default) or week (7 days)."
        }
      }
    }
  end

  @impl true
  def annotations, do: %{read_only: true, open_world: true}
  @impl true
  def connections, do: [:plane, :forgejo, :argus]

  @impl true
  def example do
    %{
      args: %{"scope" => "today"},
      output: """
      # My work (today)

      ## My Plane items (2 open)

      ### In Progress

      | ID | Title | Priority | Due |
      |---|---|---|---|
      | DEMO-12 | Export invoices as CSV | high | 2026-11-30 |

      ## Pull requests

      | PR | Title | Why | State | CI |
      |---|---|---|---|---|
      | [demo/app#42](https://git.example.com/demo/app/pulls/42) | Export invoices as CSV | yours | open | ❌ failure |

      ## Recent errors (last 24 h)

      <untrusted source="argus">
      | Project | ID | Title | Events | Last seen | Yours? |
      |---|---|---|---|---|---|
      | demo-api | 7 | KeyError: 'currency' | 12 | 2026-11-26 09:40 | ⚠️ billing/views.py in `4f2c9e1a3b` |
      </untrusted>

      ## Shipped (last 7 days)

      | Release | Status | Health | Highlights |
      |---|---|---|---|
      | demo release-demo.3 | 🚀 success | 🟡 yellow (watching the first 24 h) | 1 |

      **Notes**
      - Argus is not connected. Link it at https://mcp.example.com/connections
      """
    }
  end

  @impl true
  def call(scope, args) do
    window = if args["scope"] == "week", do: :week, else: :today
    since = DateTime.add(DateTime.utc_now(), -if(window == :week, do: 7, else: 1) * 86_400)

    results =
      FanOut.run(
        [
          {:plane, :plane, fn -> plane(scope) end},
          {:prs, :forgejo, fn -> prs(scope) end},
          {:errors, :argus, fn -> errors(scope, since) end},
          {:commits, :forgejo, fn -> my_commits(scope, since) end},
          {:releases, :releases,
           fn ->
             Releases.list(since: DateTime.add(DateTime.utc_now(), -7 * 86_400), limit: 100)
           end}
        ],
        timeout: @budget
      )

    sections = [
      plane_section(results.plane),
      pr_section(results.prs),
      error_section(results.errors, results.commits, window),
      shipped_section(scope, results.releases)
    ]

    md =
      "# My work (#{window})\n\n" <>
        (sections |> Enum.map(&elem(&1, 0)) |> Enum.join("\n\n"))

    notes = Enum.flat_map(sections, &elem(&1, 1)) ++ commit_notes(results.commits)
    {:ok, md |> with_notes(notes) |> Markdown.cap(16_000)}
  end

  ## Fetching (each runs in its own task)

  defp plane(scope) do
    with {:ok, cred} <- Upstreams.credential(scope, :plane) do
      Plane.my_items(cred, scope.user.id)
    end
  end

  defp prs(scope) do
    mine = Forgejo.search_prs(scope, state: "open", created: true, limit: 20)
    asked = Forgejo.search_prs(scope, state: "open", review_requested: true, limit: 20)

    with {:ok, mine} <- mine, {:ok, asked} <- asked do
      tagged =
        Enum.map(mine, &{&1, "yours"}) ++
          for(
            pr <- asked,
            pr["id"] not in Enum.map(mine, & &1["id"]),
            do: {pr, "review requested"}
          )

      details =
        tagged
        |> Enum.take(@max_prs)
        |> Task.async_stream(fn {pr, why} -> {pr, why, ci(scope, pr)} end,
          timeout: 7_000,
          on_timeout: :kill_task
        )
        |> Enum.zip(Enum.take(tagged, @max_prs))
        |> Enum.map(fn
          {{:ok, done}, _} -> done
          {_, {pr, why}} -> {pr, why, "–"}
        end)

      {:ok, details, length(tagged)}
    end
  end

  defp ci(scope, issue) do
    with {:ok, owner, repo} <-
           Forgejo.parse_repo(get_in(issue, ["repository", "full_name"]) || ""),
         {:ok, pr} <- Forgejo.pull(scope, owner, repo, issue["number"]),
         {:ok, status} <- Forgejo.status(scope, owner, repo, get_in(pr, ["head", "sha"])) do
      if status["statuses"] in [nil, []],
        do: "–",
        else: ForgejoRender.check_state(status["state"])
    else
      _ -> "–"
    end
  end

  @doc false
  # Unresolved Argus issues seen since `since` in the busiest projects (also used by workflows).
  def errors(scope, since) do
    with {:ok, cred} <- Upstreams.credential(scope, :argus),
         {:ok, projects} <- Switchboard.Argus.projects(cred) do
      busy =
        projects
        |> Enum.filter(&(&1["unresolved"] > 0))
        |> Enum.sort_by(& &1["unresolved"], :desc)
        |> Enum.take(@max_error_projects)

      rows =
        busy
        |> Task.async_stream(
          fn p ->
            case Switchboard.Argus.issues(cred, p["slug"], status: "unresolved", per_page: 10) do
              {:ok, rows, _} -> Enum.map(rows, &Map.put(&1, "project", p["slug"]))
              _ -> []
            end
          end,
          timeout: 7_000,
          on_timeout: :kill_task
        )
        |> Enum.flat_map(fn
          {:ok, rows} -> rows
          _ -> []
        end)
        |> Enum.filter(fn r ->
          case to_datetime(r["last_seen"]) do
            %DateTime{} = dt -> DateTime.compare(dt, since) != :lt
            nil -> true
          end
        end)
        |> Enum.sort_by(& &1["last_seen"], :desc)

      {:ok, rows, length(busy) < Enum.count(projects, &(&1["unresolved"] > 0))}
    end
  end

  @doc false
  # The caller's own commits in their recently updated repos, with changed files.
  def my_commits(scope, since) do
    with {:ok, %{"data" => repos}} <- Forgejo.my_repos(scope, scope.user.forgejo_id, 5) do
      commits =
        repos
        |> Task.async_stream(
          fn r ->
            {:ok, owner, name} = Forgejo.parse_repo(r["full_name"])

            case Forgejo.commits(scope, owner, name, 30) do
              {:ok, list} -> Enum.map(list, &Map.put(&1, "repo", r["full_name"]))
              _ -> []
            end
          end,
          timeout: 7_000,
          on_timeout: :kill_task
        )
        |> Enum.flat_map(fn
          {:ok, list} -> list
          _ -> []
        end)
        |> Enum.filter(fn c ->
          author = get_in(c, ["author", "login"])
          date = to_datetime(get_in(c, ["commit", "author", "date"]))

          is_binary(author) and String.downcase(author) == String.downcase(scope.user.username) and
            match?(%DateTime{}, date) and DateTime.compare(date, since) != :lt
        end)

      {:ok, commits}
    end
  end

  ## Rendering

  defp plane_section({:ok, items, notes}), do: {PlaneMyItems.render(items) |> demote(), notes}
  defp plane_section({:error, reason}), do: {"## My Plane items\n\n–", [problem(:plane, reason)]}

  defp pr_section({:ok, [], _}),
    do: {"## Pull requests\n\nNo open pull requests of yours or waiting for your review.", []}

  defp pr_section({:ok, details, total}) do
    rows =
      Enum.map(details, fn {pr, why, ci} ->
        repo = get_in(pr, ["repository", "full_name"]) || "?"

        [
          "[#{repo}##{pr["number"]}](#{pr["html_url"]})",
          cell(pr["title"], 70),
          why,
          ForgejoRender.pr_state(pr),
          ci
        ]
      end)

    more =
      if total > length(details),
        do: ["#{total - length(details)} more pull requests; use repo_search_prs."],
        else: []

    {"## Pull requests\n\n" <> table(["PR", "Title", "Why", "State", "CI"], rows), more}
  end

  defp pr_section({:error, reason}), do: {"## Pull requests\n\n–", [problem(:forgejo, reason)]}

  defp error_section({:ok, [], _}, _commits, window),
    do:
      {"## Recent errors (#{window_label(window)})\n\nNo unresolved errors seen in projects you can see.",
       []}

  defp error_section({:ok, rows, partial?}, commits, window) do
    my_files =
      case commits do
        {:ok, list} -> for c <- list, f <- c["files"] || [], do: {f["filename"], c["sha"]}
        _ -> []
      end

    table_rows =
      rows
      |> Enum.take(15)
      |> Enum.map(fn r ->
        yours =
          case culprit_match(r["culprit"], my_files) do
            {file, sha} -> "⚠️ #{cell(file, 60)} in `#{String.slice(sha, 0, 10)}`"
            nil -> ""
          end

        [
          cell(r["project"]),
          r["id"],
          cell(r["title"], 70),
          to_string(r["events"]),
          Markdown.datetime(r["last_seen"]),
          yours
        ]
      end)

    notes =
      if partial?,
        do: [
          "Errors: only the #{@max_error_projects} projects with most unresolved issues were checked."
        ],
        else: []

    {"## Recent errors (#{window_label(window)})\n\n" <>
       untrusted(
         table(["Project", "ID", "Title", "Events", "Last seen", "Yours?"], table_rows),
         "argus"
       ), notes}
  end

  defp error_section({:error, reason}, _commits, window),
    do: {"## Recent errors (#{window_label(window)})\n\n–", [problem(:argus, reason)]}

  defp commit_notes({:error, reason}),
    do: ["Your commits (for matching errors): " <> problem(:forgejo, reason)]

  defp commit_notes(_), do: []

  defp shipped_section(scope, {:ok, releases}) do
    names = my_names(scope)

    mine =
      Enum.filter(releases, fn r ->
        Enum.any?(r["authors"] || [], &(String.downcase(&1) in names)) or
          String.downcase(r["actor"] || "") in names
      end)

    if mine == [] do
      {"## Shipped (last 7 days)\n\nNothing of yours shipped in the last 7 days.", []}
    else
      rows =
        Enum.map(mine, fn r ->
          highlights =
            if is_list(r["highlights"]), do: to_string(length(r["highlights"])), else: "–"

          [
            "#{r["repo"]} #{r["name"]}",
            ReleaseRender.status(r),
            ReleaseRender.health(r),
            highlights
          ]
        end)

      {"## Shipped (last 7 days)\n\n" <>
         table(["Release", "Status", "Health", "Highlights"], rows) <>
         "\n\nDetails: release with repo and name.", []}
    end
  end

  defp shipped_section(_scope, {:error, reason}),
    do: {"## Shipped (last 7 days)\n\n–", [problem(:releases, reason)]}

  # Release authors are Rocket.Chat usernames; use the Forgejo one and, when linked, Rocket.Chat's.
  defp my_names(scope) do
    rc =
      case Switchboard.Connections.get(scope.user, "rocketchat") do
        %{identity: %{"username" => u}} when is_binary(u) -> [String.downcase(u)]
        _ -> []
      end

    Enum.uniq([String.downcase(scope.user.username) | rc])
  end

  @doc """
  Whether an error's culprit points at one of the files: matches the path, the path without
  extension, or its dotted module name (`billing/views.py` → `billing.views`).
  """
  def culprit_match(nil, _files), do: nil
  def culprit_match("", _files), do: nil

  def culprit_match(culprit, files) do
    culprit = String.downcase(culprit)

    Enum.find(files, fn {file, _sha} ->
      file = String.downcase(file || "")
      no_ext = Path.rootname(file)
      dotted = String.replace(no_ext, "/", ".")
      short = dotted |> String.split(".") |> Enum.take(-2) |> Enum.join(".")

      Enum.any?(
        [file, no_ext, dotted, short],
        &(String.length(&1) >= 6 and String.contains?(culprit, &1))
      )
    end)
  end

  defp window_label(:today), do: "last 24 h"
  defp window_label(:week), do: "last 7 days"

  # Sub-sections one level down inside My work.
  defp demote(md), do: String.replace(md, ~r/^(#+) /m, "#\\1 ")
end
