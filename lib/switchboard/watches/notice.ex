defmodule Switchboard.Watches.Notice do
  @moduledoc """
  The text of a watch notice, in the owner's language (`users.locale`). Short, with a link to
  what happened and one back to the person's watches. Built only from the watch's `last_state`
  (statuses, names, links and release highlights); `Switchboard.Tools.NotifyMe.notice/2` then
  defuses mentions and adds the automatic-notice footer.
  """
  use Gettext, backend: SwitchboardWeb.Gettext

  alias Switchboard.Watches.Watch

  @max_highlights 5

  def render(%Watch{user: user} = watch, notice) do
    Gettext.with_locale(SwitchboardWeb.Gettext, user.locale || "es", fn ->
      body(watch, notice) <> "\n" <> gettext("Your watches: %{url}", url: watches_url())
    end)
  end

  def watches_url, do: Switchboard.OAuth.issuer() <> "/watches"

  defp body(%Watch{end_reason: reason} = watch, "result")
       when reason not in [nil, "notified"],
       do: stopped(watch, reason)

  defp body(%Watch{kind: "ci", last_state: s} = watch, "result") do
    label = Watch.label(watch)
    url = get_in(s, ["runs", Access.at(0), "url"]) || ""

    head =
      case s["result"] do
        "success" -> gettext("✅ CI passed: %{what}", what: label)
        "failure" -> gettext("❌ CI failed: %{what}", what: label)
        "cancelled" -> gettext("⚪ CI was cancelled: %{what}", what: label)
        other -> gettext("CI finished (%{status}): %{what}", status: other, what: label)
      end

    failed =
      for run <- s["runs"] || [], job <- run["failed"] || [] do
        if job["step"],
          do: gettext("Job %{job}, step \"%{step}\"", job: job["job"], step: job["step"]),
          else: gettext("Job %{job}", job: job["job"])
      end

    Enum.join([head | failed] ++ [url], "\n")
  end

  defp body(%Watch{kind: "task", last_state: s} = watch, "result") do
    id = Watch.label(watch)

    head =
      case s["event"] do
        "released" ->
          gettext("🚀 %{id} shipped in %{repo} %{release}.",
            id: id,
            repo: s["release_repo"],
            release: s["release"]
          )

        _ ->
          gettext("%{id} moved to %{state} (was %{previous}).",
            id: id,
            state: s["state"],
            previous: s["previous_state"] || "?"
          )
      end

    Enum.join([head, s["url"] || ""], "\n")
  end

  defp body(%Watch{kind: "release", last_state: s}, "result") do
    head =
      gettext("%{icon} Release %{repo} %{name}: %{status}",
        icon: status_icon(s["status"]),
        repo: s["repo"],
        name: s["name"],
        status: s["status"]
      )

    highlights =
      case s["highlights"] do
        [_ | _] = list ->
          list
          |> Enum.take(@max_highlights)
          |> Enum.map(&("> " <> String.slice(to_string(&1), 0, 200)))

        _ ->
          []
      end

    Enum.join([head, s["run_url"] || ""] ++ highlights, "\n")
  end

  defp body(%Watch{kind: "release", last_state: s}, "health") do
    head =
      gettext("%{icon} Release %{repo} %{name} after 24 h: %{health}",
        icon: health_icon(s["health"]),
        repo: s["repo"],
        name: s["name"],
        health: s["health"] || gettext("unknown")
      )

    issues =
      for i <- s["issues"] || [] do
        "- " <> String.slice(to_string(i["title"]), 0, 120) <> " " <> to_string(i["url"])
      end

    issues =
      if issues == [],
        do: [gettext("No new errors from this release.")],
        else: [gettext("Errors it introduced:") | issues]

    Enum.join([head | issues], "\n")
  end

  defp stopped(watch, reason) do
    what = Watch.label(watch)

    case reason do
      "timed_out" ->
        gettext("⌛ Your watch on %{what} expired before anything happened.", what: what)

      "connection_missing" ->
        gettext(
          "Your watch on %{what} stopped: the connection it needs is no longer linked.",
          what: what
        )

      "connection_rejected" ->
        gettext("Your watch on %{what} stopped: your key was rejected. Link it again.",
          what: what
        )

      "access_lost" ->
        gettext("Your watch on %{what} stopped: you no longer have access to it.", what: what)

      _ ->
        gettext("Your watch on %{what} stopped.", what: what)
    end
  end

  defp status_icon("success"), do: "🚀"
  defp status_icon("failure"), do: "❌"
  defp status_icon(_), do: "⚪"

  defp health_icon("green"), do: "🟢"
  defp health_icon("yellow"), do: "🟡"
  defp health_icon("red"), do: "🔴"
  defp health_icon(_), do: "⚪"
end
