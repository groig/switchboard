defmodule Switchboard.Onboarding do
  @moduledoc """
  Where a person is on the way from "never heard of it" to "my agent just did something useful",
  for the Get started page (`/start`), the `help` workflow and the admin Onboarding view.

  Nothing here is tracked separately; every answer comes from existing records:

    * **agent connected** - the person's latest MCP audit row (which client, when);
    * **activated** - at least one successful MCP call (until then `/start` is the landing page);
    * **accounts** - `Switchboard.Connections` (linked, missing or error);
    * **tried** - the distinct tools and workflows in their successful MCP audit rows, which tick
      off the `prompts/0` checklist.

  `samples/2` personalizes the prompts with one of the person's own open Plane items and a recent
  Argus issue, read with their own credentials through the cached clients; anything unavailable
  falls back to a placeholder.
  """
  use Gettext, backend: SwitchboardWeb.Gettext

  import Ecto.Query

  alias Switchboard.Accounts.User
  alias Switchboard.Audit.Event
  alias Switchboard.{Cache, Connections, FanOut, Repo, Scope, Upstreams, Workflows}

  @samples_ttl :timer.minutes(5)

  ## The checklist

  @typedoc """
  A ready-to-copy prompt. `text` is an English msgid (translated on the page with Gettext) that
  may use `%{task}` or `%{error}`; `needs` are the systems it can't work without; `done_by` are
  the audit actions (tool names or `workflow:<name>`) that tick it off.
  """
  @type prompt :: %{
          id: String.t(),
          group: :look | :work | :wow,
          text: String.t(),
          needs: [String.t()],
          done_by: [String.t()]
        }

  @prompts [
    %{
      id: "next",
      group: :look,
      text: gettext_noop("What should I work on next?"),
      needs: ["plane"],
      done_by: ["workflow:next", "my_work"]
    },
    %{
      id: "dms",
      group: :look,
      text: gettext_noop("What DMs do I need to answer?"),
      needs: ["rocketchat"],
      done_by: ["chat_inbox", "workflow:inbox"]
    },
    %{
      id: "errors",
      group: :look,
      text: gettext_noop("Any new errors in my projects?"),
      needs: ["argus"],
      done_by: ["error_list"]
    },
    %{
      id: "release",
      group: :look,
      text: gettext_noop("What shipped in the last release?"),
      needs: [],
      done_by: ["release"]
    },
    %{
      id: "ci",
      group: :work,
      text: gettext_noop("Why did CI fail on my last PR?"),
      needs: [],
      done_by: ["ci_failure"]
    },
    %{
      id: "pickup",
      group: :work,
      text: gettext_noop("Pick up %{task}"),
      needs: ["plane"],
      done_by: ["workflow:pickup"]
    },
    %{
      id: "status",
      group: :work,
      text: gettext_noop("Where is %{task} at? PRs, CI and release."),
      needs: ["plane"],
      done_by: ["task_status"]
    },
    %{
      id: "image",
      group: :work,
      text: gettext_noop("Show me the screenshots in %{task}."),
      needs: ["plane"],
      done_by: ["plane_get_image"]
    },
    %{
      id: "watch",
      group: :work,
      text: gettext_noop("Tell me when CI finishes on this PR."),
      needs: [],
      done_by: ["watch_ci"]
    },
    %{
      id: "docs",
      group: :work,
      text: gettext_noop("Search the wiki for how we deploy."),
      needs: ["outline"],
      done_by: ["docs_search", "docs_read"]
    },
    %{
      id: "standup",
      group: :wow,
      text: gettext_noop("Draft my standup."),
      needs: ["plane"],
      done_by: ["workflow:standup"]
    },
    %{
      id: "triage",
      group: :wow,
      text: gettext_noop("Triage %{error} and suggest a fix."),
      needs: ["argus"],
      done_by: ["workflow:triage", "error_get"]
    },
    %{
      id: "handoff",
      group: :wow,
      text: gettext_noop("Hand off %{task} to QA."),
      needs: ["plane"],
      done_by: ["workflow:handoff"]
    }
  ]

  @doc "The Try these prompts, from simple to impressive."
  @spec prompts() :: [prompt()]
  def prompts, do: @prompts

  @doc "Audit actions of successful MCP calls by the user (the tools and workflows they tried)."
  def tried(%User{id: id}) do
    from(e in Event,
      where: e.user_id == ^id and e.kind == "mcp" and e.outcome == "ok",
      distinct: true,
      select: e.action
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc "Whether a prompt is ticked off by the tried actions."
  def done?(%{done_by: actions}, tried), do: Enum.any?(actions, &MapSet.member?(tried, &1))

  @doc "Whether every system a prompt needs is linked and working."
  def ready?(%{needs: needs}, accounts),
    do: Enum.all?(needs, &(status_of(accounts, &1) == :linked))

  @doc "The systems a prompt needs that aren't linked and working (in display order)."
  def missing(%{needs: needs}, accounts),
    do: Enum.filter(needs, &(status_of(accounts, &1) != :linked))

  @doc """
  Up to `n` prompts to suggest: ready and not tried yet first (in checklist order), then the ones
  that need an account that isn't linked.
  """
  def suggestions(accounts, tried, n \\ 3) do
    open = Enum.reject(@prompts, &done?(&1, tried))
    {ready, blocked} = Enum.split_with(open, &ready?(&1, accounts))
    Enum.take(ready ++ blocked, n)
  end

  @doc """
  Fills a prompt's placeholders: the person's own task and error when known, `<task>` and
  `<error>` otherwise. `text` is the (possibly translated) template.
  """
  def fill(text, samples) do
    text
    |> String.replace("%{task}", samples[:task] || "<task>")
    |> String.replace("%{error}", samples[:error] || "<error>")
  end

  ## The agent

  @doc """
  The person's latest MCP call through any client: `%{client: name, at: datetime}`, or nil when
  no agent has called Switchboard yet.
  """
  def agent(%User{id: id}) do
    from(e in Event,
      where: e.user_id == ^id and e.kind == "mcp",
      order_by: [desc: e.at],
      limit: 1,
      select: %{client: e.client_name, at: e.at}
    )
    |> Repo.one()
  end

  @doc "Whether the person has made at least one successful MCP call (the landing-page rule)."
  def activated?(%User{id: id}) do
    Repo.exists?(
      from e in Event, where: e.user_id == ^id and e.kind == "mcp" and e.outcome == "ok"
    )
  end

  @doc """
  The MCP client behind a scope: `:claude_code`, `:codex` or `:other` (a personal token or an
  unknown client). Known by the CIMD client id, else by the client's name.
  """
  def client_kind(%Scope{client_id: id, client_name: name}) do
    text = "#{id} #{name}" |> String.downcase()

    cond do
      text =~ "claude" -> :claude_code
      text =~ "codex" or text =~ "chatgpt.com" -> :codex
      true -> :other
    end
  end

  ## Accounts

  @doc """
  One entry per system, in display order: `%{system, label, status, connection, optional}`
  where `status` is `:linked` (usable), `:missing` or `:error` (the key was rejected, or belongs
  to someone else). A key stored untested still counts as linked: tools use it. `optional`
  systems (GitHub: only for repositories that live there) don't count as missing for "every
  account linked".
  """
  def accounts(%Scope{} = scope) do
    connections = Connections.list(scope)

    for mod <- Upstreams.all() do
      conn = connections[mod.system()]

      %{
        system: mod.system(),
        label: mod.label(),
        status: status(conn),
        connection: conn,
        optional: function_exported?(mod, :optional?, 0) and mod.optional?()
      }
    end
  end

  @doc false
  def status(nil), do: :missing
  def status(%{status: "rejected"}), do: :error
  def status(%{identity_matches: false}), do: :error
  def status(%{}), do: :linked

  defp status_of(accounts, system) do
    case Enum.find(accounts, &(&1.system == system)) do
      nil -> :missing
      a -> a.status
    end
  end

  @doc "The workflow names that read a system (for \"Plane unlocks: next, pickup...\")."
  def workflows_using(system) do
    atom = system_atom(system)

    for mod <- Workflows.all(), atom in mod.connections(), do: mod.name()
  end

  @doc """
  What linking a system gives, in a few words (an English Gettext msgid; the page translates it).
  """
  def unlocks("forgejo"), do: gettext_noop("your pull requests, CI and reviews")
  def unlocks("plane"), do: gettext_noop("your tasks and their comments")
  def unlocks("argus"), do: gettext_noop("errors in your projects")
  def unlocks("outline"), do: gettext_noop("wiki search and drafts")
  def unlocks("rocketchat"), do: gettext_noop("your DMs and mentions, and messages you approve")

  def unlocks("github"),
    do: gettext_noop("pull requests, checks and Actions logs of repositories on GitHub")

  @systems %{
    "forgejo" => :forgejo,
    "plane" => :plane,
    "argus" => :argus,
    "outline" => :outline,
    "rocketchat" => :rocketchat,
    "github" => :github
  }

  defp system_atom(system), do: Map.fetch!(@systems, system)

  @doc "Where a system is linked: its row on the Connections page."
  def connection_url(system),
    do: Switchboard.OAuth.issuer() <> "/connections#connection-#{system}"

  def start_url, do: Switchboard.OAuth.issuer() <> "/start"

  ## Personalized samples

  @doc """
  One of the person's own open Plane items (`task: "PROJ-12"`) and a recent unresolved Argus
  issue (`error: "project/7"`), read with their own credentials, within a short budget. Missing
  keys mean the data isn't available (not linked, failing, nothing open). Cached for a few
  minutes per person.

  With `cached_only: true` it makes no upstream call: it returns what the page last fetched, or
  the Plane item from the cached `my_items` read.
  """
  def samples(%Scope{user: user} = scope, opts \\ []) do
    key = {:onboarding_samples, user.id}

    if opts[:cached_only] do
      case Cache.peek(key) do
        {:ok, samples} -> samples
        :error -> cached_task(scope)
      end
    else
      {:ok, samples} = Cache.fetch(key, @samples_ttl, fn -> {:ok, fetch_samples(scope)} end)
      samples
    end
  end

  defp fetch_samples(scope) do
    FanOut.run(
      [
        {:task, :plane, fn -> sample_task(scope) end},
        {:error, :argus, fn -> sample_error(scope) end}
      ],
      timeout: FanOut.budget(8_000)
    )
    |> Enum.flat_map(fn
      {key, {:ok, value}} when is_binary(value) -> [{key, value}]
      _ -> []
    end)
    |> Map.new()
  end

  defp sample_task(scope) do
    with {:ok, cred} <- Upstreams.credential(scope, :plane),
         {:ok, items, _notes} <- Switchboard.Plane.my_items(cred, scope.user.id) do
      first_identifier(items)
    end
  end

  defp cached_task(scope) do
    with {:ok, cred} <- Upstreams.credential(scope, :plane),
         {:ok, items} <- Switchboard.Plane.cached_my_items(cred, scope.user.id),
         {:ok, task} <- first_identifier(items) do
      %{task: task}
    else
      _ -> %{}
    end
  end

  defp first_identifier(items) do
    case Switchboard.Plane.sort_items(items) do
      [%{"identifier" => id} | _] when is_binary(id) -> {:ok, id}
      _ -> {:error, :none}
    end
  end

  # The project with the most unresolved issues the person can see, then its latest issue.
  defp sample_error(scope) do
    with {:ok, cred} <- Upstreams.credential(scope, :argus),
         {:ok, projects} <- Switchboard.Argus.projects(cred),
         %{"slug" => slug} <-
           projects
           |> Enum.filter(&((&1["unresolved"] || 0) > 0))
           |> Enum.max_by(& &1["unresolved"], fn -> nil end),
         {:ok, [%{"id" => id} | _], _text} <-
           Switchboard.Argus.issues(cred, slug, status: "unresolved", per_page: 1),
         true <- slug =~ ~r/^[\w.\-]{1,80}$/ and id =~ ~r/^\w{1,40}$/ do
      {:ok, "#{slug}/#{id}"}
    else
      {:error, _} = error -> error
      _ -> {:error, :none}
    end
  end

  ## The admin view

  @doc """
  Every person's progress, for the admin Onboarding view: `%{user, agent, accounts_linked,
  optional_linked, prompts_tried, last_active}`, most recently active first. `accounts_*`
  count the systems everyone needs; `optional_linked` lists the optional ones (GitHub) they
  linked. Four queries, whatever the number of
  people.
  """
  def overview do
    users = Repo.all(from u in User, order_by: u.username)
    ids = Enum.map(users, & &1.id)

    linked =
      from(c in Switchboard.Connections.Connection,
        where: c.user_id in ^ids,
        select: {c.user_id, c.system, c.status, c.identity_matches}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0))

    last_active =
      from(e in Event,
        where: e.user_id in ^ids,
        group_by: e.user_id,
        select: {e.user_id, max(e.at)}
      )
      |> Repo.all()
      |> Map.new()

    agents =
      from(e in Event,
        where: e.user_id in ^ids and e.kind == "mcp",
        distinct: e.user_id,
        order_by: [asc: e.user_id, desc: e.at],
        select: {e.user_id, %{client: e.client_name, at: e.at}}
      )
      |> Repo.all()
      |> Map.new()

    tried =
      from(e in Event,
        where: e.user_id in ^ids and e.kind == "mcp" and e.outcome == "ok",
        distinct: true,
        select: {e.user_id, e.action}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    {optional, required} =
      Upstreams.all()
      |> Enum.split_with(&(function_exported?(&1, :optional?, 0) and &1.optional?()))
      |> then(fn {o, r} -> {Enum.map(o, & &1.system()), Enum.map(r, & &1.system())} end)

    total = length(required)

    users
    |> Enum.map(fn user ->
      user_tried = MapSet.new(Map.get(tried, user.id, []))

      usable =
        for {_, system, status, matches} <- Map.get(linked, user.id, []),
            status(%{status: status, identity_matches: matches}) == :linked,
            do: system

      ok = Enum.filter(usable, &(&1 in required))

      %{
        user: user,
        agent: agents[user.id],
        activated: Enum.any?(user_tried),
        accounts_linked: length(ok),
        accounts_total: total,
        optional_linked: Enum.filter(optional, &(&1 in usable)),
        prompts_tried: Enum.count(@prompts, &done?(&1, user_tried)),
        prompts_total: length(@prompts),
        last_active: last_active[user.id]
      }
    end)
    |> Enum.sort_by(&(&1.last_active || ~U[1970-01-01 00:00:00Z]), {:desc, DateTime})
  end
end
