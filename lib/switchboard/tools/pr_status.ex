defmodule Switchboard.Tools.PrStatus do
  @moduledoc "A pull request's reviews, mergeability and CI checks."
  use Switchboard.Tools.Support

  alias Switchboard.{FanOut, Repos}
  alias Switchboard.Tools.ForgejoRender

  @impl true
  def name, do: "pr_status"
  @impl true
  def title, do: "Pull request status"
  @impl true
  def description,
    do:
      "Shows a pull request's state, reviews, whether it can be merged, and its CI checks, on " <>
        "Forgejo or GitHub (check runs and commit statuses). Use ci_failure for the log of a " <>
        "failed check."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "repo" => %{"type" => "string", "description" => Repos.schema_description()},
        "number" => %{
          "type" => "integer",
          "description" => "Pull request number (optional when repo is a pull request URL)."
        }
      },
      "required" => ["repo"]
    }
  end

  @impl true
  def aliases,
    do: %{
      "repository" => "repo",
      "pr" => "number",
      "pr_number" => "number",
      "index" => "number",
      "pull" => "number",
      "pull_request" => "number"
    }

  @impl true
  def annotations, do: %{read_only: true, open_world: true}
  @impl true
  def connections, do: [:forgejo, :github]

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
  def call(scope, %{"repo" => repo} = args) do
    with {:ok, ref} <- Repos.resolve(repo),
         {:ok, number} <- number(args, ref) do
      case Repos.client(ref).pull(scope, ref.owner, ref.name, number) do
        {:ok, pr} ->
          {:ok, render(scope, ref, pr)}

        {:error, :not_found} ->
          {:error,
           Repos.missing(
             scope,
             ref,
             "No pull request #{Repos.Ref.full(ref)}##{number}, or you can't see it."
           )}

        {:error, reason} ->
          {:error, Repos.problem(ref, reason)}
      end
    end
  end

  defp number(%{"number" => n}, _ref) when is_integer(n), do: {:ok, n}
  defp number(_args, %{pr: n}) when is_integer(n), do: {:ok, n}

  defp number(_args, _ref),
    do: {:error, "Give the pull request number (number), or a pull request URL as repo."}

  defp render(scope, ref, pr) do
    %{owner: owner, name: name, host: host} = ref
    client = Repos.client(ref)
    sha = get_in(pr, ["head", "sha"])

    extra =
      FanOut.run(
        [
          {:reviews, host, fn -> client.reviews(scope, owner, name, pr["number"]) end},
          {:status, host, fn -> client.status(scope, owner, name, sha) end}
        ],
        timeout: 8_000
      )

    {reviews, notes} =
      case extra.reviews do
        {:ok, r} -> {ForgejoRender.reviews_summary(r, pr["requested_reviewers"]), []}
        {:error, reason} -> {"–", ["Reviews: " <> problem(host, reason)]}
      end

    {checks, notes} =
      case extra.status do
        {:ok, s} -> {ForgejoRender.checks(s), notes}
        {:error, reason} -> {"–", notes ++ ["Checks: " <> problem(host, reason)]}
      end

    facts =
      table(["", ""], [
        ["State", ForgejoRender.pr_state(pr)],
        ["Author", cell(get_in(pr, ["user", "login"]))],
        [
          "Branches",
          "#{cell(get_in(pr, ["head", "ref"]))} → #{cell(get_in(pr, ["base", "ref"]))}"
        ],
        ["Mergeable", ForgejoRender.mergeable(pr)],
        ["Reviews", cell(reviews, 300)],
        ["Head", "`#{String.slice(sha || "", 0, 10)}`"],
        ["Updated", time(pr["updated_at"], scope)],
        ["Link", pr["html_url"] || "–"]
      ])

    "## #{owner}/#{name}##{pr["number"]}: #{cell(pr["title"], 200)}\n\n#{facts}\n\n### Checks\n\n#{checks}"
    |> with_notes(notes)
  end
end
