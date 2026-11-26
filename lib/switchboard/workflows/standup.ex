defmodule Switchboard.Workflows.Standup do
  @moduledoc """
  `standup`: draft my standup. Prefetches what the person did since the last working day
  (Plane items they changed, pull requests they opened, merged or reviewed), what's on for today
  and what's blocked; the agent adds their local commits and writes yesterday / today / blockers.
  """
  @behaviour Switchboard.Workflow
  use Gettext, backend: SwitchboardWeb.Gettext

  alias Switchboard.Workflows.Facts

  @budget 12_000

  @impl true
  def name, do: "standup"
  @impl true
  def title, do: "Draft my standup"
  @impl true
  def purpose, do: gettext_noop("Draft your standup: yesterday, today and blockers")
  @impl true
  def description,
    do:
      "Draft my standup (yesterday, today, blockers) from Plane, Forgejo and my local commits; " <>
        "optionally post it to a channel after I confirm."

  @impl true
  def arguments,
    do: [
      %{
        name: "channel",
        description: "Channel to offer posting it to, e.g. #team-standup.",
        required: false
      }
    ]

  @impl true
  def connections, do: [:plane, :forgejo]
  @impl true
  def fetches,
    do: [
      "Plane items assigned to or created by you that changed since the last working day (Friday on Mondays)",
      "pull requests you opened, merged or reviewed since then",
      "your items in progress, due today or overdue",
      "your pull requests with failed CI or requested changes"
    ]

  @impl true
  def writes, do: ["send_message"]

  @impl true
  def example,
    do: %{
      args: %{"channel" => "#demo-standup"},
      says: gettext_noop("Draft my standup for #demo-standup")
    }

  @impl true
  def build(scope, args, ctx) do
    with :ok <- Facts.check_channel(args["channel"]), do: build_ok(scope, args, ctx)
  end

  defp build_ok(scope, args, ctx) do
    {day, since} = Facts.last_working_day(scope, ctx.now)
    today = Facts.today(scope, ctx.now)

    r =
      Facts.gather(
        [
          {:changed, :plane,
           fn ->
             Facts.plane_recent(
               scope,
               since,
               "No Plane item assigned to you or created by you changed since then."
             )
           end},
          {:prs, :forgejo, fn -> Facts.pr_activity(scope, since) end},
          {:today, :plane,
           fn ->
             Facts.plane_open(scope, today,
               only: &(Facts.flags(&1, today) != ""),
               empty: "Nothing of yours is in progress, due today or overdue."
             )
           end},
          {:attention, :forgejo,
           fn ->
             Facts.my_prs(scope,
               only_attention: true,
               empty: "No pull request of yours has failed CI or requested changes."
             )
           end}
        ],
        @budget
      )

    {facts, notes} =
      Facts.render([
        {"Plane items you changed since #{Calendar.strftime(day, "%A %Y-%m-%d")}", r.changed},
        {"Pull requests you opened, merged or reviewed since #{day}", r.prs},
        {"In progress, due today or overdue", r.today},
        {"Your pull requests with failed CI or requested changes", r.attention}
      ])

    channel = args["channel"]

    post =
      cond do
        "send_message" not in ctx.writes ->
          "Don't offer to post it: sending messages is unavailable right now."

        channel ->
          "Offer to post it to `#{channel}` with `send_message`: show the exact text and " <>
            "the channel, and send only after the user approves that exact text."

        true ->
          "Ask whether they want it posted, and where. If they name a channel, show the exact " <>
            "text and the channel and send it with `send_message` only after they approve it."
      end

    {:ok,
     %{
       steps: [
         "Run `git log --since=\"#{Date.to_iso8601(day)} 00:00\" --author=\"$(git config user.email)\" " <>
           "--oneline --all` in the user's checkout (and any other repo they mention) to add their " <>
           "local commits, including ones not pushed yet. Mention unpushed work as such.",
         "Combine the commits with the Facts. Items in the Facts are assigned to or created by the " <>
           "user; Plane can't tell who made each change, so don't claim they did something the " <>
           "facts don't show.",
         "Write the standup in #{Switchboard.Workflows.language(ctx.locale)}, three short parts: " <>
           "**Yesterday** (since #{day}: what moved, what merged, what they reviewed), **Today** " <>
           "(in progress, due today, overdue) and **Blockers** (blocked items, failed CI, requested " <>
           "changes, or \"none\"). One line per point, task ids and PR links kept, no filler.",
         "Show the draft and ask for corrections.",
         post
       ],
       facts: facts,
       notes: notes
     }}
  end
end
