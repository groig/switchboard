defmodule Switchboard.Workflows.Next do
  @moduledoc """
  `next`: what should I work on now? Prefetches open Plane items, review requests, the person's
  pull requests that need attention, errors pointing at their changes and the number of DMs
  waiting; the agent ranks at most five, unblocking others first.
  """
  @behaviour Switchboard.Workflow
  use Gettext, backend: SwitchboardWeb.Gettext

  alias Switchboard.Workflows.Facts

  @budget 12_000

  @impl true
  def name, do: "next"
  @impl true
  def title, do: "What should I work on now?"
  @impl true
  def purpose, do: gettext_noop("What to do now: at most 5 things, each with a reason")
  @impl true
  def description,
    do:
      "What should I work on now? Ranks at most 5 things (reviews and failures that block others " <>
        "first, then due dates and priority), each with one line saying why."

  @impl true
  def arguments, do: []
  @impl true
  def connections, do: [:plane, :forgejo, :github, :argus, :rocketchat, :releases]
  @impl true
  def fetches,
    do: [
      "your open Plane items with state, priority and due date",
      "pull requests waiting for your review",
      "your pull requests with failed CI or requested changes (open, or merged in the last 48 h)",
      "unresolved Argus errors from the last 24 h that point at files you changed this week, and errors the release triage tied to your releases",
      "how many DMs wait for your answer (a count only)"
    ]

  @impl true
  def writes, do: []

  @impl true
  def example, do: %{args: %{}, says: gettext_noop("What should I work on next?")}

  @impl true
  def build(scope, _args, ctx) do
    today = Facts.today(scope, ctx.now)

    r =
      Facts.gather(
        [
          {:plane, :plane, fn -> Facts.plane_open(scope, today, limit: 20) end},
          {:reviews, Switchboard.Repos.systems(scope), fn -> Facts.review_requests(scope) end},
          {:mine, Switchboard.Repos.systems(scope),
           fn ->
             Facts.my_prs(scope,
               since: DateTime.add(ctx.now, -2 * 86_400),
               only_attention: true,
               empty:
                 "No pull request of yours has failed CI or requested changes (open, or merged in the last 48 h)."
             )
           end},
          {:errors, :argus, fn -> Facts.my_errors(scope, ctx.now) end},
          {:dms, :rocketchat, fn -> Facts.dms_waiting(scope) end}
        ],
        @budget
      )

    {facts, notes} =
      Facts.render([
        {"Pull requests waiting for your review", r.reviews},
        {"Your pull requests that need attention", r.mine},
        {"Errors that may be yours", r.errors},
        {"Your open Plane items (most urgent first)", r.plane},
        {"Direct messages", r.dms}
      ])

    {:ok,
     %{
       steps: [
         "Rank what's in the Facts and give **at most 5** things to do now, each with one line " <>
           "saying why. Order: first what unblocks other people (reviews waiting for them, failed " <>
           "CI on work that is already merged, errors that started after a release of theirs, " <>
           "requested changes on their pull requests), then due dates (overdue, due today, soon), " <>
           "then priority (urgent, high...). Items marked in progress beat untouched ones of the " <>
           "same rank.",
         "If DMs are waiting, add one line with the count only and suggest the `inbox` workflow; " <>
           "don't read them here.",
         "Where it helps decide, glance at the local checkout (`git status`, the current branch, " <>
           "`git log -5 --oneline`) to see what they were in the middle of, and say so.",
         "Use pr_status, ci_failure, error_get or task_status only if one of the top items needs a " <>
           "detail to be ranked; don't fetch everything.",
         "End with one question: \"Start on <the first item>?\". If they say yes and it is a Plane " <>
           "task, continue with the `pickup` workflow for it (the `workflow` tool with name " <>
           "\"pickup\" if slash commands aren't available)."
       ],
       facts: facts,
       notes: notes
     }}
  end
end
