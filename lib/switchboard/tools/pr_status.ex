defmodule Switchboard.Tools.PrStatus do
  @moduledoc "A pull request's reviews, mergeability and CI checks."
  use Switchboard.Tools.Support

  alias Switchboard.{FanOut, Forgejo}
  alias Switchboard.Tools.ForgejoRender

  @impl true
  def name, do: "pr_status"
  @impl true
  def title, do: "Pull request status"
  @impl true
  def description,
    do:
      "Shows a Forgejo pull request's state, reviews, whether it can be merged, and its CI " <>
        "checks. Use ci_failure for the log of a failed check."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "repo" => %{"type" => "string", "description" => "owner/name, e.g. acme/web."},
        "number" => %{"type" => "integer", "description" => "Pull request number."}
      },
      "required" => ["repo", "number"]
    }
  end

  @impl true
  def annotations, do: %{read_only: true, open_world: true}
  @impl true
  def connections, do: [:forgejo]

  @impl true
  def example do
    %{
      args: %{"repo" => "demo/app", "number" => 42},
      output: """
      ## demo/app#42: Export invoices as CSV

      | | |
      |---|---|
      | State | open |
      | Author | ana |
      | Branches | feature/csv → main |
      | Mergeable | yes |
      | Reviews | bruno: approved; carla: review requested |
      | Updated | 2026-11-26 09:12 (Europe/Madrid) |
      | Link | https://git.example.com/demo/app/pulls/42 |

      ### Checks

      Overall: **❌ failure**

      | Check | State | Description | Link |
      |---|---|---|---|
      | ci / test (push) | ❌ failure | Failing after 2m | https://git.example.com/demo/app/actions/runs/7/jobs/0 |
      """
    }
  end

  @impl true
  def call(scope, %{"repo" => repo, "number" => number}) do
    with {:ok, owner, name} <- Forgejo.parse_repo(repo) |> repo_error() do
      case Forgejo.pull(scope, owner, name, number) do
        {:ok, pr} ->
          {:ok, render(scope, owner, name, pr)}

        {:error, :not_found} ->
          {:error, "No pull request #{repo}##{number}, or you can't see it."}

        {:error, reason} ->
          {:error, problem(:forgejo, reason)}
      end
    end
  end

  defp repo_error({:error, :invalid_repo}), do: {:error, "repo must be owner/name"}
  defp repo_error(ok), do: ok

  defp render(scope, owner, name, pr) do
    sha = get_in(pr, ["head", "sha"])

    extra =
      FanOut.run(
        [
          {:reviews, :forgejo, fn -> Forgejo.reviews(scope, owner, name, pr["number"]) end},
          {:status, :forgejo, fn -> Forgejo.status(scope, owner, name, sha) end}
        ],
        timeout: 8_000
      )

    {reviews, notes} =
      case extra.reviews do
        {:ok, r} -> {ForgejoRender.reviews_summary(r, pr["requested_reviewers"]), []}
        {:error, reason} -> {"–", ["Reviews: " <> problem(:forgejo, reason)]}
      end

    {checks, notes} =
      case extra.status do
        {:ok, s} -> {ForgejoRender.checks(s), notes}
        {:error, reason} -> {"–", notes ++ ["Checks: " <> problem(:forgejo, reason)]}
      end

    facts =
      table(["", ""], [
        ["State", ForgejoRender.pr_state(pr)],
        ["Author", cell(get_in(pr, ["user", "login"]))],
        [
          "Branches",
          "#{cell(get_in(pr, ["head", "ref"]))} → #{cell(get_in(pr, ["base", "ref"]))}"
        ],
        ["Mergeable", if(pr["mergeable"], do: "yes", else: "no (conflicts or blocked)")],
        ["Reviews", cell(reviews, 300)],
        ["Head", "`#{String.slice(sha || "", 0, 10)}`"],
        ["Updated", time(pr["updated_at"], scope)],
        ["Link", pr["html_url"] || "–"]
      ])

    "## #{owner}/#{name}##{pr["number"]}: #{cell(pr["title"], 200)}\n\n#{facts}\n\n### Checks\n\n#{checks}"
    |> with_notes(notes)
  end
end
