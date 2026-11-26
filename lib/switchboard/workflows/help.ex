defmodule Switchboard.Workflows.Help do
  @moduledoc """
  `help`: what Switchboard can do for me, and what's left to set up. Makes no upstream call: it
  reads Switchboard's own records (the person, their connections, the tools and workflows they
  already used) and, when one is cached, an open Plane item to personalize the suggestions.
  Shares its data with the Get started page (`Switchboard.Onboarding`).
  """
  @behaviour Switchboard.Workflow
  use Gettext, backend: SwitchboardWeb.Gettext

  alias Switchboard.{Onboarding, Workflows}

  @impl true
  def name, do: "help"
  @impl true
  def title, do: "What can Switchboard do for me?"
  @impl true
  def purpose, do: gettext_noop("What Switchboard can do for you, and what's left to set up")
  @impl true
  def description,
    do:
      "What can Switchboard do for me? Shows who you are, which accounts are linked or missing " <>
        "(with the link to fix them), the team commands and how to run them here, and three " <>
        "things to try next."

  @impl true
  def arguments, do: []
  @impl true
  def connections, do: []
  @impl true
  def fetches,
    do: [
      "nothing upstream: your profile, your linked accounts and the tools and workflows you already used (Switchboard's own records)",
      "one of your open Plane items for the suggestions, only if it is already cached"
    ]

  @impl true
  def writes, do: []

  @impl true
  def example, do: %{args: %{}, says: gettext_noop("What can Switchboard do for me?")}

  @impl true
  def build(scope, _args, _ctx) do
    accounts = Onboarding.accounts(scope)
    tried = Onboarding.tried(scope.user)
    samples = Onboarding.samples(scope, cached_only: true)
    client = Onboarding.client_kind(scope)

    facts =
      Enum.join(
        [
          you(scope, client),
          accounts_md(accounts),
          commands_md(client),
          suggestions_md(Onboarding.suggestions(accounts, tried, 3), accounts, samples)
        ]
        |> Enum.map(&String.trim/1),
        "\n\n"
      )

    {:ok,
     %{
       steps: [
         "Give the user a short overview in their language: who they are and which accounts " <>
           "are linked. Keep it brief; show the tables below only as compact lists.",
         "For each account that is missing or has an error, say in one line what it unlocks and " <>
           "give its link. Keys are linked in the browser at that link: never ask the user to " <>
           "paste a key in the chat.",
         "List the commands with how to run them in this client (see Commands).",
         "Offer the suggestions in Try next. If the user picks one, do it (for a command, run " <>
           "that workflow).",
         "Don't call other tools to double-check: these facts are current."
       ],
       facts: facts,
       notes: []
     }}
  end

  defp you(scope, client) do
    user = scope.user

    name =
      if user.name in [nil, ""], do: "@#{user.username}", else: "#{user.name} (@#{user.username})"

    via = scope.client_name || scope.client_id || "a personal token"

    """
    ### You

    #{name}, language `#{user.locale || "es"}`, connected through #{via} (#{client_label(client)}).
    Get started page (setup checklist): #{Onboarding.start_url()}
    """
  end

  defp client_label(:claude_code), do: "Claude Code"
  defp client_label(:codex), do: "Codex"
  defp client_label(:other), do: "another MCP client"

  defp accounts_md(accounts) do
    rows =
      Enum.map_join(accounts, "\n", fn a ->
        "| #{a.label} | #{status_md(a)} | #{unlocks(a.system)} |"
      end)

    """
    ### Accounts

    | System | Status | What it unlocks |
    |---|---|---|
    #{rows}
    """
  end

  defp status_md(%{system: "forgejo", status: :linked}), do: "linked (from sign-in)"
  defp status_md(%{status: :linked}), do: "linked"

  defp status_md(%{system: "forgejo"}),
    do: "error: sign out and sign in again at #{Onboarding.start_url()}"

  defp status_md(%{system: s, status: :missing}),
    do: "**missing**: link it at #{Onboarding.connection_url(s)}"

  defp status_md(%{system: s, connection: %{identity_matches: false}}),
    do:
      "**error**: the key belongs to someone else; link your own at #{Onboarding.connection_url(s)}"

  defp status_md(%{system: s}),
    do: "**error**: the key was rejected; link it again at #{Onboarding.connection_url(s)}"

  defp unlocks(system) do
    case Onboarding.workflows_using(system) do
      [] -> Onboarding.unlocks(system)
      names -> Onboarding.unlocks(system) <> "; " <> Enum.map_join(names, ", ", &"`#{&1}`")
    end
  end

  defp commands_md(client) do
    rows =
      Enum.map_join(Workflows.all(), "\n", fn mod ->
        "| `#{mod.name()}` | #{mod.purpose()} | #{invocation(mod, client)} |"
      end)

    """
    ### Commands

    #{how(client)}

    | Command | What for | How to run it here |
    |---|---|---|
    #{rows}
    """
  end

  defp how(:claude_code),
    do:
      "In Claude Code each command is a slash command: `/mcp__switchboard__<name>`, with its " <>
        "arguments after it, separated by spaces (`switchboard` is the name the server was " <>
        "added with; use theirs if they picked another). Plain words work too."

  defp how(:codex),
    do:
      "Codex has no slash commands for these: the user asks in plain words and you run the " <>
        "`workflow` tool with the command's `name` and `args`."

  defp how(:other),
    do:
      "If this client offers MCP prompts, each command is a slash command named after it. " <>
        "Otherwise the user asks in plain words and you run the `workflow` tool with the " <>
        "command's `name` and `args`."

  defp invocation(mod, :claude_code) do
    args =
      Enum.map_join(mod.arguments(), "", &" #{mod.example().args[&1.name] || "<#{&1.name}>"}")

    "`/mcp__switchboard__#{mod.name()}#{args}`"
  end

  defp invocation(mod, _client), do: "\"#{mod.example().says}\""

  defp suggestions_md([], _accounts, _samples),
    do: "### Try next\n\nThey have tried every suggestion on the Get started page."

  defp suggestions_md(prompts, accounts, samples) do
    items =
      prompts
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {p, i} ->
        text = Onboarding.fill(p.text, samples)

        case Onboarding.missing(p, accounts) do
          [] ->
            "#{i}. \"#{text}\""

          missing ->
            links = Enum.map_join(missing, ", ", &Onboarding.connection_url/1)
            "#{i}. \"#{text}\" (needs #{Enum.map_join(missing, " and ", &label/1)}: #{links})"
        end
      end)

    """
    ### Try next

    Things they haven't tried yet, from the Get started page. `<task>` or `<error>` means they \
    pick one (a Plane task id, an Argus issue).

    #{items}
    """
  end

  defp label(system) do
    case Switchboard.Upstreams.fetch(system) do
      {:ok, mod} -> mod.label()
      :error -> system
    end
  end
end
