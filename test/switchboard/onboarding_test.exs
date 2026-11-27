defmodule Switchboard.OnboardingTest do
  # Get started data and the `help` workflow, against synthetic upstreams (no real data).
  use Switchboard.DataCase, async: true

  import Switchboard.OAuthFixtures

  alias Switchboard.Connections.Connection
  alias Switchboard.{Audit, Onboarding, Scope, UpstreamStubs, Workflows}

  defp scope(user, opts \\ [client_name: "Claude Code"]), do: Scope.for_user(user, opts)

  defp link(user, system, attrs \\ %{}) do
    Repo.insert!(
      struct!(
        %Connection{
          user_id: user.id,
          system: system,
          secret: %{"token" => "#{system}-#{user.id}"},
          status: "ok"
        },
        attrs
      )
    )
  end

  defp statuses(scope), do: Map.new(Onboarding.accounts(scope), &{&1.system, &1.status})

  # Reports every upstream request to the test process.
  defp spy_upstreams do
    test = self()

    Req.Test.stub(Switchboard.Upstreams, fn conn ->
      send(test, {:upstream, conn.host, conn.request_path})
      Req.Test.json(conn, %{})
    end)
  end

  describe "accounts" do
    test "linked, missing or error (rejected, or someone else's key)" do
      user = user_fixture()
      link(user, "plane")
      link(user, "argus", %{status: "rejected"})
      link(user, "outline", %{identity_matches: false})
      # Stored while the system was down: tools still use it.
      link(user, "rocketchat", %{status: "untested"})

      assert statuses(scope(user)) == %{
               "forgejo" => :linked,
               "plane" => :linked,
               "argus" => :error,
               "outline" => :error,
               "rocketchat" => :linked,
               # Optional: only for repositories on GitHub.
               "github" => :missing
             }

      assert [%{system: "github", optional: true}] =
               Enum.filter(Onboarding.accounts(scope(user)), & &1.optional)
    end

    test "what each system unlocks comes from the workflow registry" do
      assert "pickup" in Onboarding.workflows_using("plane")
      assert "triage" in Onboarding.workflows_using("argus")
      refute "triage" in Onboarding.workflows_using("outline")
      refute "help" in Onboarding.workflows_using("plane")
    end
  end

  describe "tried and the agent step" do
    test "successful MCP calls tick prompts off; failures and web actions don't" do
      user = user_fixture()
      s = scope(user)
      assert Onboarding.agent(user) == nil
      refute Onboarding.activated?(user)

      Audit.log_tool(s, "error_list", %{}, outcome: "error")
      Audit.log_web(s, "connection.linked", %{system: "plane"})
      assert %{client: "Claude Code"} = Onboarding.agent(user)
      refute Onboarding.activated?(user)

      Audit.log_tool(s, "workflow:next", %{}, outcome: "ok")
      Audit.log_tool(s, "chat_inbox", %{}, outcome: "ok")
      tried = Onboarding.tried(user)
      assert Onboarding.activated?(user)

      done = for p <- Onboarding.prompts(), Onboarding.done?(p, tried), do: p.id
      assert Enum.sort(done) == ["dms", "next"]
    end

    test "suggestions: linked and untried first, then the ones that need an account" do
      user = user_fixture()
      s = scope(user)
      Audit.log_tool(s, "release", %{}, outcome: "ok")

      [first, second, third] =
        Onboarding.suggestions(Onboarding.accounts(s), Onboarding.tried(user), 3)

      # Only Forgejo is linked: CI and the CI watch are ready; release was tried.
      assert [first.id, second.id] == ["ci", "watch"]
      assert third.needs != []
    end

    test "the client behind a scope" do
      user = user_fixture()

      assert Onboarding.client_kind(
               scope(user,
                 client_id: "https://claude.ai/oauth/claude-code-client-metadata",
                 client_name: "Claude Code"
               )
             ) == :claude_code

      assert Onboarding.client_kind(
               scope(user, client_id: "https://chatgpt.com/oauth/codex/client.json")
             ) == :codex

      assert Onboarding.client_kind(scope(user, client_name: "laptop", via: :personal_token)) ==
               :other
    end
  end

  describe "personalized samples" do
    test "one of their own open Plane items and a recent Argus issue" do
      UpstreamStubs.stub()
      user = user_fixture() |> UpstreamStubs.link_all()

      assert %{task: "DEMO-" <> _, error: "demo-api/7"} = Onboarding.samples(scope(user))
    end

    test "missing or failing upstreams fall back to placeholders" do
      UpstreamStubs.stub(%{"argus.test" => {:status, 500}})
      user = user_fixture()
      link(user, "argus", %{secret: %{"token" => "argus_key"}})

      samples = Onboarding.samples(scope(user))
      assert samples == %{}
      assert Onboarding.fill("Pick up %{task}", samples) == "Pick up <task>"
      assert Onboarding.fill("Triage %{error}", samples) == "Triage <error>"
    end

    test "cached_only makes no upstream call" do
      spy_upstreams()
      user = user_fixture() |> UpstreamStubs.link_all()

      assert Onboarding.samples(scope(user), cached_only: true) == %{}
      refute_received {:upstream, _, _}
    end
  end

  describe "the help workflow" do
    setup do
      spy_upstreams()
      :ok
    end

    defp help!(scope) do
      assert {:ok, text} = Workflows.run(scope, "help", %{})
      refute_received {:upstream, _, _}
      text
    end

    test "a new person: Forgejo linked, the rest missing with links to the exact rows" do
      user = user_fixture(%{username: "pat", name: "Pat Example"})
      text = help!(scope(user))

      assert text =~ "Pat Example (@pat)"
      assert text =~ "| Forgejo | linked (from sign-in) |"

      for system <- ~w(plane argus outline rocketchat) do
        assert text =~
                 "**missing**: link it at http://localhost:4002/connections#connection-#{system}"
      end

      assert text =~ "http://localhost:4002/start"
      # Ready suggestions first: only Forgejo is linked.
      assert text =~ ~s(1. "What shipped in the last release?")
      assert text =~ ~s(2. "Why did CI fail on my last PR?")

      Audit.log_tool(scope(user), "ci_failure", %{}, outcome: "ok")
      Audit.log_tool(scope(user), "release", %{}, outcome: "ok")
      text = help!(scope(user))
      assert text =~ ~s(1. "Tell me when CI finishes on this PR.")

      assert text =~
               ~s(2. "What should I work on next?" (needs Plane: http://localhost:4002/connections#connection-plane\))
    end

    test "rejected and someone else's keys are errors; linked ones say what they unlock" do
      user = user_fixture()
      link(user, "plane")
      link(user, "argus", %{status: "rejected"})
      link(user, "outline", %{identity_matches: false})
      text = help!(scope(user))

      assert text =~ ~r/\| Plane \| linked \| your tasks and their comments; .*`pickup`/

      assert text =~
               "**error**: the key was rejected; link it again at http://localhost:4002/connections#connection-argus"

      assert text =~ "**error**: the key belongs to someone else"
    end

    test "how to run the commands depends on the client" do
      user = user_fixture()

      claude =
        help!(scope(user, client_id: "https://claude.ai/oauth/claude-code-client-metadata"))

      assert claude =~ "`/mcp__switchboard__pickup DEMO-12`"
      assert claude =~ "`/mcp__switchboard__help`"

      codex = help!(scope(user, client_id: "https://chatgpt.com/oauth/codex/client.json"))
      assert codex =~ "Codex has no slash commands"
      assert codex =~ ~s("Let's pick up DEMO-12")
      refute codex =~ "/mcp__switchboard__pickup"

      other = help!(scope(user, client_name: "laptop", via: :personal_token))
      assert other =~ "If this client offers MCP prompts"

      for mod <- Workflows.all(), do: assert(claude =~ "| `#{mod.name()}` |")
    end

    test "suggestions leave out what was tried, and use a cached task" do
      UpstreamStubs.stub()
      user = user_fixture() |> UpstreamStubs.link_all()
      s = scope(user)

      for action <- ~w(workflow:next error_list release ci_failure),
          do: Audit.log_tool(s, action, %{}, outcome: "ok")

      %{task: task} = Onboarding.samples(s)

      spy_upstreams()
      text = help!(s)
      refute text =~ ~s("What should I work on next?")
      assert text =~ ~s(1. "Pick up #{task}")
      assert text =~ ~s(2. "Where is #{task} at? PRs, CI and release.")
    end

    test "the prompt and the workflow tool give the same text, audited once" do
      user = user_fixture()
      s = scope(user)
      {:ok, prompt} = Workflows.run(s, "help", %{})
      {:ok, tool} = Switchboard.Tools.run(s, "workflow", %{"name" => "help"})

      strip = &String.replace(&1, ~r/run \w+ \d{4}-\d\d-\d\d \d\d:\d\d/, "")
      assert strip.(prompt) == strip.(tool)
      assert Onboarding.tried(user) == MapSet.new(["workflow:help"])
    end
  end

  test "the admin overview counts each person's steps" do
    UpstreamStubs.stub()
    pat = user_fixture()
    ana = user_fixture() |> UpstreamStubs.link_all()
    Audit.log_tool(scope(ana), "workflow:next", %{}, outcome: "ok")
    Audit.log_tool(scope(ana), "error_list", %{}, outcome: "ok")

    rows = Map.new(Onboarding.overview(), &{&1.user.id, &1})

    assert %{agent: nil, activated: false, accounts_linked: 1, prompts_tried: 0} = rows[pat.id]

    assert %{
             agent: %{client: "Claude Code"},
             activated: true,
             accounts_linked: 4,
             accounts_total: 5,
             prompts_tried: 2,
             prompts_total: 14
           } = rows[ana.id]
  end
end
