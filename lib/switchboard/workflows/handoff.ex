defmodule Switchboard.Workflows.Handoff do
  @moduledoc """
  `handoff <task> [channel]`: hand a task over to QA. Prefetches the Plane item, its pull
  requests with CI and the release it's in (`task_status`), and the project's states; the agent
  drafts the QA message from those and the local diff, and offers to post it, comment on the item
  and move it to the QA state, each with its own confirmation.
  """
  @behaviour Switchboard.Workflow
  use Gettext, backend: SwitchboardWeb.Gettext

  alias Switchboard.Plane
  alias Switchboard.Tools.{PlaneGetItem, TaskStatus}
  alias Switchboard.Workflows.Facts

  import Switchboard.Tools.Support

  @budget 12_000

  @impl true
  def name, do: "handoff"
  @impl true
  def title, do: "Hand a task over to QA"
  @impl true
  def purpose, do: gettext_noop("Hand a task over to QA with a test plan")
  @impl true
  def description,
    do:
      "Hand a task over to QA: drafts what changed, how to test it, the risks and where it's " <>
        "deployed; offers to post it, comment on the task and move it to QA, each after I confirm."

  @impl true
  def arguments,
    do: [
      %{name: "task", description: "Plane work item, e.g. PROJ-123.", required: true},
      %{
        name: "channel",
        description: "Channel to offer posting the QA message to, e.g. #qa.",
        required: false
      }
    ]

  @impl true
  def connections, do: [:plane, :forgejo, :github, :releases]
  @impl true
  def fetches,
    do: [
      "the Plane item (`plane_get_item`)",
      "its pull requests, CI and the release it shipped in (`task_status`)",
      "the states of its Plane project (to find the QA one)"
    ]

  @impl true
  def writes, do: ["send_message", "plane_comment", "plane_set_state"]

  @impl true
  def example,
    do: %{
      args: %{"task" => "DEMO-12", "channel" => "#demo-qa"},
      says: gettext_noop("Hand DEMO-12 over to QA in #demo-qa")
    }

  @impl true
  def build(scope, args, ctx) do
    with {:ok, id} <- Facts.task_id(args["task"]),
         :ok <- Facts.check_channel(args["channel"]) do
      r =
        Facts.gather(
          [
            {:item, :plane, fn -> Facts.tool(scope, PlaneGetItem, %{"id" => id}) end},
            {:status, Switchboard.Repos.systems(scope),
             fn -> Facts.tool(scope, TaskStatus, %{"id" => id}) end},
            {:states, :plane, fn -> states(scope, id) end}
          ],
          @budget
        )

      {facts, notes} =
        Facts.render([
          {"The task", r.item},
          {"Pull requests, CI and deploys (task_status)", r.status},
          {"States of its Plane project", r.states}
        ])

      {:ok, %{steps: steps(id, args["channel"], ctx), facts: facts, notes: notes}}
    end
  end

  defp steps(id, channel, ctx) do
    lang = Switchboard.Workflows.language(ctx.locale)

    offers =
      [
        "send_message" in ctx.writes &&
          if(channel,
            do: "post the message to `#{channel}` with `send_message`",
            else: "post the message to a channel they name, with `send_message`"
          ),
        "plane_comment" in ctx.writes && "add it as a comment on #{id} with `plane_comment`",
        "plane_set_state" in ctx.writes &&
          "move #{id} to the QA state with `plane_set_state` (pick it from the project's states " <>
            "above; if none is clearly QA, ask which one)"
      ]
      |> Enum.filter(& &1)

    offer_step =
      if offers == [],
        do:
          "Don't offer to post, comment or change the task: those tools are unavailable right now.",
        else:
          "Then offer, one at a time: " <>
            Enum.join(offers, "; ") <>
            ". Each write gets its own confirmation of the exact text or change and its destination; " <>
            "a yes to one is not a yes to the others."

    [
      "Look at the change locally: the pull requests' branches or merge commits from the Facts, " <>
        "`git log` and `git diff` against the base branch (e.g. `git diff main...<branch> --stat`, " <>
        "then the relevant hunks). Base the message on the code, not only on the descriptions.",
      "Draft a QA message in #{lang}: **What changed** (for a tester, not a developer), **How to " <>
        "test** (numbered steps with data and expected results, including edge cases from the " <>
        "diff), **Risks** (what else the change touches, migrations, flags) and **Where** (the " <>
        "release or deploy from the Facts, or \"not deployed yet\"). Keep #{id} and the PR links.",
      "If CI failed or a pull request isn't merged, say so at the top and ask whether to hand it " <>
        "over anyway.",
      "Show the draft and ask for corrections.",
      offer_step
    ]
  end

  # The item's project states, so the agent can name the QA one.
  defp states(scope, id) do
    with {:ok, cred} <- cred(scope, :plane),
         {:ok, item} <- Plane.item(cred, id),
         {:ok, states} <- Plane.states(cred, scope.user.id, item["project"]) do
      current = get_in(item, ["state", "name"])

      list =
        Enum.map_join(states, ", ", fn s ->
          name = cell(s["name"], 40)
          if s["name"] == current, do: "**#{name}** (current)", else: name
        end)

      {:ok, untrusted(list, "plane", item: id)}
    else
      {:error, reason} when not is_binary(reason) -> {:error, problem(:plane, reason)}
      other -> other
    end
  end
end
