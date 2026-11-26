defmodule Switchboard.Tools.ReleaseRender do
  @moduledoc "Markdown for release cards (shared by release, task_status, my_work)."
  import Switchboard.Tools.Support

  @doc "The full card."
  def card(r, scope) do
    facts =
      table(["", ""], [
        ["Status", status(r)],
        ["Started", time(r["startedAt"], scope)],
        ["Finished", time(r["finishedAt"], scope)],
        ["By", cell(r["actor"])],
        ["Commit", "`#{String.slice(r["sha"] || "", 0, 10)}`"],
        ["Previous", cell(r["previous"])],
        [
          "Changes",
          "#{r["commitCount"] || 0} commits, #{r["migrations"] || 0} migrations; authors: #{cell(Enum.join(r["authors"] || [], ", "))}"
        ],
        ["Health", health(r)],
        ["Pipeline", r["runUrl"] || "–"],
        ["Card", r["cardUrl"] || "–"]
      ])

    """
    ## #{r["repo"]} #{r["name"]}

    #{facts}

    ### Highlights

    #{highlights(r)}

    ### Tasks

    #{tasks(r)}

    ### Errors after the release

    #{issues(r)}
    """
    |> String.trim_trailing()
  end

  @doc "One-line status with an icon."
  def status(%{"status" => "success"}), do: "🚀 success"
  def status(%{"status" => "deploying"}), do: "⏳ deploying"
  def status(%{"status" => "failure"}), do: "❌ failure"
  def status(%{"status" => s}), do: cell(s)

  def health(%{"health" => nil}), do: "–"

  def health(%{"health" => h} = r) do
    icon = %{"green" => "🟢", "yellow" => "🟡", "red" => "🔴"}[h] || ""
    "#{icon} #{h}" <> if(r["watching"], do: " (watching the first 24 h)", else: "")
  end

  def health(_), do: "–"

  defp highlights(%{"highlights" => nil}), do: "Being prepared."

  defp highlights(%{"highlights" => []}),
    do: "Nothing visible to the business (technical changes)."

  defp highlights(%{"highlights" => list}) when is_list(list),
    do: untrusted(Enum.map_join(list, "\n", &("- " <> to_string(&1))), "releases")

  defp highlights(_), do: "–"

  defp tasks(%{"tasks" => [_ | _] = tasks}) do
    rows =
      Enum.map(tasks, fn t ->
        how =
          case t["match"] do
            "mentioned" ->
              "named in a commit"

            "matched" ->
              "matched from the changes" <>
                if(t["evidence"], do: ": " <> cell(t["evidence"], 80), else: "")

            other ->
              cell(other)
          end

        [cell(t["id"]), how, t["url"] || "–"]
      end)

    table(["Task", "How", "Link"], rows)
  end

  defp tasks(_), do: "None linked."

  @doc "The Argus issues table of a release (titles are untrusted)."
  def issues(%{"argusIssues" => [_ | _] = issues}) do
    rows =
      Enum.map(issues, fn i ->
        [
          cell(i["id"]),
          cell(i["title"], 90),
          if(i["fromRelease"], do: "**yes**", else: "no"),
          i["url"] || "–"
        ]
      end)

    untrusted(table(["ID", "Title", "From this release", "Link"], rows), "argus")
  end

  def issues(%{"status" => "success"}), do: "None so far."
  def issues(_), do: "–"
end
