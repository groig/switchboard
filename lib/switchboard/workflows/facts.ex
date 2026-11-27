defmodule Switchboard.Workflows.Facts do
  @moduledoc """
  The prefetch building blocks the workflows share. Each returns `{:ok, markdown}`,
  `{:ok, markdown, notes}` or `{:error, line}`; `render/1` turns a list of titled results into the
  Facts sections and their Notes.

  Everything reads with the caller's own credentials, as the tools do, and every piece of upstream
  text (titles included) is inside an `<untrusted>` block. Sections that reuse a tool's output
  (`tool/3`) honour that tool's kill switch.
  """

  import Switchboard.Tools.Support
  alias Switchboard.Markdown

  alias Switchboard.{Controls, FanOut, Forgejo, Plane, Releases, Upstreams, Watches}
  alias Switchboard.Tools.{ChatInbox, ForgejoRender, MyWork, WatchSupport}
  alias Switchboard.Watches.Watch

  @max_prs 8

  @doc "Runs `{key, system, fun}` entries concurrently within the budget (`FanOut`)."
  def gather(entries, budget), do: FanOut.run(entries, timeout: FanOut.budget(budget))

  @doc """
  Renders `[{title, result}]` as `### title` sections. A failed one shows "–" and adds a note
  starting with its title.
  """
  def render(sections) do
    {mds, notes} =
      Enum.map_reduce(sections, [], fn {title, result}, notes ->
        case result do
          {:ok, md} -> {"### #{title}\n\n#{String.trim(md)}", notes}
          {:ok, md, more} -> {"### #{title}\n\n#{String.trim(md)}", notes ++ more}
          {:error, line} -> {"### #{title}\n\n–", notes ++ ["#{title}: #{reason_line(line)}"]}
        end
      end)

    {Enum.join(mds, "\n\n"), notes}
  end

  defp reason_line(line) when is_binary(line), do: line
  defp reason_line(:timeout), do: "didn't answer in time."
  defp reason_line(:crashed), do: "failed unexpectedly (logged)."
  defp reason_line(other), do: inspect(other)

  @doc """
  A tool's own output as a section, two heading levels down. Refused when an administrator
  switched the tool off; the tool's errors become the section's note.
  """
  def tool(scope, mod, args) do
    if Controls.tool_enabled?(mod.name()) do
      case mod.call(scope, args) do
        {:ok, md} when is_binary(md) -> {:ok, demote(md)}
        # Workflows are text (prompts): a tool's images stay out of them.
        {:ok, %{text: md}} -> {:ok, demote(md)}
        {:error, message} -> {:error, to_string(message)}
      end
    else
      {:error, "#{mod.name()} is turned off by an administrator."}
    end
  end

  @doc "Moves Markdown headings down so they nest under a `###` section."
  def demote(md), do: String.replace(md, ~r/^(#+) /m, "\\1## ")

  ## Arguments

  @doc "A channel argument: `#name`, `@user` or a bare room name; nil is fine."
  def check_channel(nil), do: :ok

  def check_channel(channel) do
    if channel =~ ~r/^[#@]?[\w.\-]{1,80}$/u,
      do: :ok,
      else: {:error, "channel must look like #channel or @user"}
  end

  @doc "A task argument: `PROJ-123`, upper-cased."
  def task_id(nil), do: {:error, "Missing arguments: task"}

  def task_id(task) do
    id = task |> String.trim() |> String.upcase()
    if Plane.identifier?(id), do: {:ok, id}, else: {:error, "task must look like PROJ-123"}
  end

  ## Time

  @doc "The person's local date today."
  def today(scope, now), do: scope |> local(now) |> DateTime.to_date()

  defp local(scope, now), do: Switchboard.TimeZones.shift(now, scope.user.time_zone)

  @doc """
  The start (UTC) of the last working day before today in the person's zone: Friday on a
  Monday or a weekend, yesterday otherwise.
  """
  def last_working_day(scope, now) do
    today = today(scope, now)

    back =
      case Date.day_of_week(today) do
        1 -> 3
        6 -> 1
        7 -> 2
        _ -> 1
      end

    day = Date.add(today, -back)
    {day, start_of(day, scope.user.time_zone)}
  end

  defp start_of(date, tz) do
    case DateTime.new(date, ~T[00:00:00], tz) do
      {:ok, dt} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:ambiguous, dt, _} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:gap, _, dt} -> DateTime.shift_zone!(dt, "Etc/UTC")
      _ -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end
  end

  ## Plane

  @doc "The person's open Plane items, most urgent first, flagged (overdue, due today, blocked)."
  def plane_open(scope, today, opts \\ []) do
    with {:ok, cred} <- cred(scope, :plane),
         {:ok, items, notes} <- Plane.my_items(cred, scope.user.id) do
      items = Plane.sort_items(items, today)
      items = if opts[:only], do: Enum.filter(items, opts[:only]), else: items
      limit = opts[:limit] || 15

      if items == [] do
        {:ok, opts[:empty] || "No open Plane items assigned to you.", notes}
      else
        rows =
          items
          |> Enum.take(limit)
          |> Enum.map(fn i ->
            [
              i["identifier"],
              cell(i["name"], 70),
              cell(get_in(i, ["state", "name"])),
              cell(i["priority"]),
              Markdown.date(i["target_date"]),
              flags(i, today)
            ]
          end)

        more =
          if length(items) > limit, do: ["#{length(items) - limit} more open items."], else: []

        {:ok,
         untrusted(table(["ID", "Title", "State", "Priority", "Due", "Flags"], rows), "plane"),
         notes ++ more}
      end
    end
    |> plane_error()
  end

  @doc "Flags for an item: overdue, due today, in progress, blocked (by state name)."
  def flags(item, today) do
    due =
      case item["target_date"] && Date.from_iso8601(String.slice(item["target_date"], 0, 10)) do
        {:ok, d} ->
          case Date.compare(d, today) do
            :lt -> ["overdue"]
            :eq -> ["due today"]
            _ -> []
          end

        _ ->
          []
      end

    state = get_in(item, ["state", "name"]) || ""

    (due ++
       if(get_in(item, ["state", "group"]) == "started", do: ["in progress"], else: []) ++
       if(state =~ ~r/block/i, do: ["blocked"], else: []))
    |> Enum.join(", ")
  end

  @doc "Plane items assigned to or created by the person and updated since `since`."
  def plane_recent(scope, since, empty) do
    with {:ok, cred} <- cred(scope, :plane),
         {:ok, items, notes} <- Plane.recent_items(cred, scope.user.id, since) do
      if items == [] do
        {:ok, empty, notes}
      else
        rows =
          items
          |> Enum.take(15)
          |> Enum.map(fn i ->
            [
              i["identifier"],
              cell(i["name"], 70),
              cell(get_in(i, ["state", "name"])),
              time(i["updated_at"], scope)
            ]
          end)

        {:ok, untrusted(table(["ID", "Title", "State", "Updated"], rows), "plane"), notes}
      end
    end
    |> plane_error()
  end

  defp plane_error({:error, reason}) when not is_binary(reason),
    do: {:error, problem(:plane, reason)}

  defp plane_error(other), do: other

  ## Forgejo

  @doc """
  The person's pull requests (open, plus merged or closed since `since` when given) with CI and
  reviews, flagged when CI failed or changes were requested. `only_attention: true` keeps the
  flagged ones.
  """
  def my_prs(scope, opts \\ []) do
    params =
      case opts[:since] do
        %DateTime{} = since -> [state: "all", since: DateTime.to_iso8601(since)]
        _ -> [state: "open"]
      end

    with {:ok, found} <- Forgejo.search_prs(scope, [created: true, limit: 20] ++ params) do
      details =
        found
        |> Enum.reject(&(&1["state"] == "closed" and not merged?(&1)))
        |> Enum.take(@max_prs)
        |> Task.async_stream(&pr_detail(scope, &1), timeout: 7_000, on_timeout: :kill_task)
        |> Enum.flat_map(fn
          {:ok, d} -> [d]
          _ -> []
        end)

      shown = if opts[:only_attention], do: Enum.filter(details, &(&1.flags != [])), else: details

      if shown == [] do
        {:ok, opts[:empty] || "No pull requests of yours need attention."}
      else
        rows =
          Enum.map(shown, fn d ->
            [
              pr_link(d.issue),
              cell(d.issue["title"], 70),
              d.state,
              d.ci,
              cell(d.reviews, 100),
              Enum.join(d.flags, ", ")
            ]
          end)

        {:ok,
         untrusted(
           table(["PR", "Title", "State", "CI", "Reviews", "Flags"], rows),
           "forgejo"
         )}
      end
    end
    |> forgejo_error()
  end

  defp merged?(issue), do: get_in(issue, ["pull_request", "merged"]) == true

  defp pr_detail(scope, issue) do
    with {:ok, owner, repo} <-
           Forgejo.parse_repo(get_in(issue, ["repository", "full_name"]) || ""),
         {:ok, pr} <- Forgejo.pull(scope, owner, repo, issue["number"]) do
      status =
        case Forgejo.status(scope, owner, repo, get_in(pr, ["head", "sha"])) do
          {:ok, %{"statuses" => [_ | _]} = s} -> s["state"]
          _ -> nil
        end

      reviews =
        case Forgejo.reviews(scope, owner, repo, pr["number"]) do
          {:ok, list} -> list
          _ -> []
        end

      summary = ForgejoRender.reviews_summary(reviews, pr["requested_reviewers"])

      flags =
        if(status in ["failure", "error"],
          do: [if(pr["merged"], do: "CI failed after merge", else: "CI failed")],
          else: []
        ) ++ if(summary =~ "changes requested", do: ["changes requested"], else: [])

      %{
        issue: issue,
        state: ForgejoRender.pr_state(pr),
        ci: ForgejoRender.check_state(status),
        reviews: summary,
        flags: flags
      }
    else
      _ ->
        %{issue: issue, state: ForgejoRender.pr_state(issue), ci: "–", reviews: "–", flags: []}
    end
  end

  @doc "Open pull requests waiting for the person's review, oldest update first."
  def review_requests(scope) do
    with {:ok, found} <-
           Forgejo.search_prs(scope, review_requested: true, state: "open", limit: 20) do
      if found == [] do
        {:ok, "No pull request is waiting for your review."}
      else
        rows =
          found
          |> Enum.sort_by(&(&1["updated_at"] || ""))
          |> Enum.take(10)
          |> Enum.map(fn pr ->
            [
              pr_link(pr),
              cell(pr["title"], 70),
              "@" <> cell(get_in(pr, ["user", "login"]), 40),
              time(pr["updated_at"], scope)
            ]
          end)

        more =
          if length(found) > 10, do: ["#{length(found) - 10} more review requests."], else: []

        {:ok, untrusted(table(["PR", "Title", "Author", "Updated"], rows), "forgejo"), more}
      end
    end
    |> forgejo_error()
  end

  @doc "Pull requests the person opened, merged or reviewed since `since`."
  def pr_activity(scope, since) do
    iso = DateTime.to_iso8601(since)

    mine = Forgejo.search_prs(scope, created: true, state: "all", since: iso, limit: 20)
    reviewed = Forgejo.search_prs(scope, reviewed: true, state: "all", since: iso, limit: 20)

    with {:ok, mine} <- mine, {:ok, reviewed} <- reviewed do
      own_ids = Enum.map(mine, & &1["id"])

      rows =
        Enum.map(mine, fn pr ->
          what =
            cond do
              merged_since?(pr, since) -> "merged"
              after?(pr["created_at"], since) -> "opened"
              true -> "updated"
            end

          [pr_link(pr), cell(pr["title"], 70), what, pr_state(pr)]
        end) ++
          for pr <- reviewed,
              pr["id"] not in own_ids,
              do: [pr_link(pr), cell(pr["title"], 70), "reviewed", pr_state(pr)]

      if rows == [],
        do: {:ok, "No pull request activity of yours since then."},
        else:
          {:ok,
           untrusted(
             table(["PR", "Title", "What you did", "State"], Enum.take(rows, 15)),
             "forgejo"
           )}
    end
    |> forgejo_error()
  end

  defp merged_since?(pr, since),
    do:
      merged?(pr) and after?(get_in(pr, ["pull_request", "merged_at"]) || pr["closed_at"], since)

  defp after?(value, since) do
    case to_datetime(value) do
      %DateTime{} = dt -> DateTime.compare(dt, since) != :lt
      nil -> false
    end
  end

  defp pr_state(pr) do
    cond do
      merged?(pr) -> "merged"
      pr["state"] == "closed" -> "closed"
      true -> "open"
    end
  end

  defp pr_link(pr) do
    repo = get_in(pr, ["repository", "full_name"]) || "?"
    "[#{cell(repo, 60)}##{pr["number"]}](#{pr["html_url"]})"
  end

  defp forgejo_error({:error, reason}) when not is_binary(reason),
    do: {:error, problem(:forgejo, reason)}

  defp forgejo_error(other), do: other

  ## Argus and releases

  @doc """
  Unresolved errors seen in the last day that point at files the person changed this week
  (`my_work`'s culprit match), and errors the release triage tied to their releases in the last
  two days.
  """
  def my_errors(scope, now) do
    day = DateTime.add(now, -86_400)
    week = DateTime.add(now, -7 * 86_400)

    with {:ok, rows, _partial} <- MyWork.errors(scope, day) do
      files =
        case MyWork.my_commits(scope, week) do
          {:ok, list} -> for c <- list, f <- c["files"] || [], do: {f["filename"], c["sha"]}
          _ -> []
        end

      mine =
        for r <- rows, match = MyWork.culprit_match(r["culprit"], files), match != nil do
          {file, sha} = match

          [
            cell(r["project"]),
            r["id"],
            cell(r["title"], 70),
            to_string(r["events"]),
            Markdown.datetime(r["last_seen"]),
            "#{cell(file, 60)} (`#{String.slice(sha, 0, 10)}`)"
          ]
        end

      others = length(rows) - length(mine)

      released = release_errors(scope, DateTime.add(now, -2 * 86_400))

      body =
        if mine == [],
          do: "No recent error points at files you changed this week.",
          else:
            untrusted(
              table(["Project", "ID", "Title", "Events", "Last seen", "Your change"], mine),
              "argus"
            )

      note =
        if others > 0,
          do: ["#{others} other unresolved errors were seen in the last 24 h (error_list)."],
          else: []

      {:ok, body <> released, note}
    else
      {:error, reason} when not is_binary(reason) -> {:error, problem(:argus, reason)}
      other -> other
    end
  end

  # Errors the release triage tied to the person's own recent releases (from the feed).
  defp release_errors(scope, since) do
    names = my_names(scope)

    case Releases.list(since: since, limit: 50) do
      {:ok, releases} ->
        rows =
          for r <- releases,
              Enum.any?(r["authors"] || [], &(String.downcase(&1) in names)),
              i <- r["argusIssues"] || [],
              i["fromRelease"] == true,
              do: [
                "#{cell(r["repo"])} #{cell(r["name"])}",
                cell(i["id"]),
                cell(i["title"], 70),
                i["url"] || "–"
              ]

        if rows == [],
          do: "",
          else:
            "\n\nErrors the release triage tied to your releases (last 48 h):\n\n" <>
              untrusted(table(["Release", "ID", "Title", "Link"], rows), "releases")

      {:error, _} ->
        ""
    end
  end

  @doc "Release authors are Rocket.Chat usernames: the Forgejo one and, when linked, Rocket.Chat's."
  def my_names(scope) do
    rc =
      case Switchboard.Connections.get(scope.user, "rocketchat") do
        %{identity: %{"username" => u}} when is_binary(u) -> [String.downcase(u)]
        _ -> []
      end

    Enum.uniq([String.downcase(scope.user.username) | rc])
  end

  ## Rocket.Chat and watches

  @doc "How many DMs wait for an answer (no message text)."
  def dms_waiting(scope) do
    if Controls.tool_enabled?("chat_inbox") do
      case ChatInbox.waiting_count(scope) do
        {:ok, 0} ->
          {:ok, "No DM is waiting for your answer."}

        {:ok, n} ->
          {:ok,
           "#{n} #{if n == 1, do: "DM waits", else: "DMs wait"} for your answer (last 7 days; may " <>
             "include bot accounts). Read them with the `inbox` workflow or chat_inbox."}

        {:error, line} ->
          {:error, line}
      end
    else
      {:error, "chat_inbox is turned off by an administrator."}
    end
  end

  @doc "The person's watches that sent their notice since `since`."
  def watches_fired(scope, since) do
    fired =
      for w <- Watches.list(scope.user),
          w.status == "fired",
          w.ended_at != nil and DateTime.compare(w.ended_at, since) != :lt,
          do: w

    if fired == [] do
      {:ok, "No watch of yours fired in the last 24 h."}
    else
      rows =
        Enum.map(fired, fn w ->
          [
            w.kind,
            cell(Watch.label(w), 80),
            WatchSupport.outcome(w),
            result(w),
            time(w.ended_at, scope)
          ]
        end)

      {:ok, table(["Kind", "What", "Outcome", "Result", "When"], rows)}
    end
  end

  defp result(%Watch{last_state: state}) when is_map(state),
    do: cell(state["result"] || state["state"] || state["status"], 40)

  defp result(_), do: "–"

  @doc "Whether a system is connected for the person (no request)."
  def connected?(scope, system), do: match?({:ok, _}, Upstreams.credential(scope, system))
end
