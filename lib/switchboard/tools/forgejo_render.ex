defmodule Switchboard.Tools.ForgejoRender do
  @moduledoc "Shared Markdown for Forgejo pull requests, reviews and checks."
  import Switchboard.Tools.Support

  @doc "One line per reviewer: their latest review state."
  def reviews_summary(reviews, requested) do
    latest =
      reviews
      |> Enum.reject(&(&1["state"] in ["COMMENT", "PENDING"] or &1["dismissed"]))
      |> Enum.group_by(&get_in(&1, ["user", "login"]))
      |> Enum.map(fn {who, rs} ->
        {who, rs |> Enum.max_by(& &1["submitted_at"]) |> Map.get("state")}
      end)

    parts =
      Enum.map(latest, fn {who, state} -> "#{who}: #{review_state(state)}" end) ++
        Enum.map(requested || [], &"#{&1["login"]}: review requested")

    if parts == [], do: "no reviews", else: Enum.join(parts, "; ")
  end

  defp review_state("APPROVED"), do: "approved"
  defp review_state("REQUEST_CHANGES"), do: "changes requested"
  defp review_state(other), do: String.downcase(to_string(other))

  @doc "The checks table from a combined status."
  def checks(%{"statuses" => statuses} = combined) when is_list(statuses) and statuses != [] do
    rows =
      Enum.map(statuses, fn s ->
        [
          cell(s["context"], 60),
          check_state(s["status"] || s["state"]),
          cell(s["description"], 60),
          s["target_url"] || "–"
        ]
      end)

    "Overall: **#{check_state(combined["state"])}**\n\n" <>
      table(["Check", "State", "Description", "Link"], rows)
  end

  def checks(_), do: "No CI checks reported."

  def check_state(s) when s in ["success"], do: "✅ success"
  def check_state(s) when s in ["failure", "error"], do: "❌ #{s}"
  def check_state(s) when s in ["pending", "running", "waiting"], do: "⏳ #{s}"
  def check_state(nil), do: "–"
  def check_state(s), do: s

  @doc "The short state of a PR."
  def pr_state(pr) do
    cond do
      pr["merged"] -> "merged"
      pr["state"] == "closed" -> "closed"
      pr["draft"] -> "draft"
      true -> "open"
    end
  end
end
