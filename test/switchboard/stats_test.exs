defmodule Switchboard.StatsTest do
  # The numbers behind /admin/stats, from audit rows seeded at known times.
  use Switchboard.DataCase, async: true

  import Switchboard.OAuthFixtures

  alias Switchboard.Audit.Event
  alias Switchboard.Connections.Connection
  alias Switchboard.{Stats, TimeZones}

  @tz "Europe/Madrid"

  defp ago(days, hours \\ 0),
    do: DateTime.utc_now() |> DateTime.add(-days * 86_400 - hours * 3600) |> DateTime.add(-60)

  defp row(user, action, at, opts \\ []) do
    %{
      id: Ecto.UUID.generate(),
      at: at,
      user_id: user && user.id,
      username: user && user.username,
      kind: Keyword.get(opts, :kind, "mcp"),
      action: action,
      client_id: opts[:client_id],
      client_name: Keyword.get(opts, :client, "Codex"),
      args: %{},
      outcome: Keyword.get(opts, :outcome, "ok"),
      error: opts[:error],
      duration_ms: Keyword.get(opts, :ms, 100),
      upstreams: Keyword.get(opts, :upstreams, ["plane"])
    }
  end

  defp link(user, system, status \\ "ok") do
    Repo.insert!(%Connection{
      user_id: user.id,
      system: system,
      secret: %{"token" => "x"},
      status: status
    })
  end

  setup do
    alice = user_fixture(%{username: "alice"})
    bob = user_fixture(%{username: "bob"})
    builder = user_fixture(%{username: "builder"})

    # Midnight edge: 23:30 UTC is already the next day in Madrid.
    edge_day = Date.utc_today() |> Date.add(-3)
    edge = DateTime.new!(edge_day, ~T[23:30:00.000000], "Etc/UTC")

    not_found = "Plane has no work item DEMO-404, or you can't see it."

    rows = [
      # alice (Codex): 4 calls in the last 7 days, one an error.
      row(alice, "plane_get_item", ago(0), ms: 100),
      row(alice, "plane_get_item", ago(1), ms: 300),
      row(alice, "plane_get_item", ago(1), outcome: "error", error: not_found, ms: 50),
      row(alice, "plane_comment", edge),
      # bob (Claude Code): a join, a workflow and an error with another id.
      row(bob, "my_work", ago(0),
        client: "Claude Code",
        upstreams: ["plane", "forgejo"],
        ms: 900
      ),
      row(bob, "workflow:standup", ago(2),
        client: "Claude Code",
        upstreams: ["plane", "forgejo", "github"]
      ),
      row(bob, "plane_get_item", ago(2),
        client: "Claude Code",
        outcome: "error",
        error: "Plane has no work item DEMO-7, or you can't see it.",
        upstreams: ["plane"]
      ),
      # The previous 7 days: one call by bob, one comment by alice.
      row(bob, "task_status", ago(9), client: "Claude Code"),
      row(alice, "plane_comment", ago(10)),
      # Excluded later: the person building the page.
      row(builder, "whoami", ago(0), upstreams: []),
      row(builder, "whoami", ago(0), upstreams: []),
      # Web rows never count as tool calls.
      row(alice, "login", ago(0), kind: "web", upstreams: [])
    ]

    Repo.insert_all(Event, rows)

    link(alice, "plane")
    link(bob, "argus", "untested")
    link(bob, "outline", "rejected")
    link(builder, "plane")

    %{alice: alice, bob: bob, builder: builder, edge: edge}
  end

  test "last 7 days, excluding the builder", %{
    alice: alice,
    bob: bob,
    builder: builder,
    edge: edge
  } do
    s = Stats.compute(:d7, [builder.id], @tz)
    h = s.headline

    assert s.compare?
    assert length(s.days) == 7
    assert h.calls == 7
    assert h.prev_calls == 2
    assert h.active == 2
    assert h.prev_active == 2
    assert_in_delta h.success, 5 / 7, 0.0001
    assert h.prev_success == 1.0
    # plane_comment is a write; my_work and the workflow are cross-system.
    assert h.writes == 1
    assert h.prev_writes == 1
    assert h.cross == 2
    # Users were created just now: all sign-ups are in this period (minus the builder).
    assert h.signups == 2
    assert h.prev_signups == 0

    # Daily buckets in Madrid: the 23:30 UTC comment counts on the next local day.
    local = edge |> TimeZones.shift(@tz) |> DateTime.to_date()
    assert local == Date.add(DateTime.to_date(edge), 1)
    assert Enum.find(s.daily, &(&1.day == local)).ok >= 1
    assert s.daily |> Enum.map(&(&1.ok + &1.error)) |> Enum.sum() == 7
    assert s.daily |> Enum.map(& &1.error) |> Enum.sum() == 2

    assert [%{action: "plane_get_item", calls: 4, ok: 2, median_ms: median} | _] = s.tools
    assert median == 100.0
    assert Stats.median([{5, 1}, {1, 1}, {3, 2}]) == 3.0
    assert Stats.median([{1, 1}, {4, 1}]) == 2.5

    assert [
             %{user_id: a, calls: 4, client: "Codex"},
             %{user_id: b, calls: 3, client: "Claude Code"}
           ] =
             s.people

    assert {a, b} == {alice.id, bob.id}
    assert Enum.find(s.people, &(&1.user_id == alice.id)).days >= 2

    assert Enum.sort_by(s.clients, & &1.client) == [
             %{client: "Claude Code", calls: 3, people: 1},
             %{client: "Codex", calls: 4, people: 1}
           ]

    assert %{system: "plane", calls: 7} in s.systems
    assert %{system: "forgejo", calls: 2} in s.systems
    assert %{system: "github", calls: 1} in s.systems

    assert s.cross.calls == 2
    assert_in_delta s.cross.share, 2 / 7, 0.0001
    assert Enum.map(s.cross.rows, & &1.action) |> Enum.sort() == ["my_work", "workflow:standup"]

    # Both "no work item" errors are one reason once the task ids are stripped.
    assert [%{action: "plane_get_item", count: 2, reason: reason}] = s.errors
    assert reason == "Plane has no work item <task>, or you can't see it."

    # Linked keys, not Forgejo (everyone has it), not rejected ones, not the builder's.
    assert s.connections.total == 2
    assert Enum.sort(s.connections.by_system) == [{"argus", 1}, {"plane", 1}]
    assert s.writes_by_tool == [{"plane_comment", 1}]
  end

  test "since launch: from the first audit row, no comparison, everyone", %{builder: builder} do
    s = Stats.compute(:launch, [], @tz)

    assert s.compare?
           |> Kernel.not()

    assert s.headline.calls == 11
    assert s.headline.active == 3
    assert s.headline.prev_calls == nil
    assert hd(s.days) == ago(10) |> TimeZones.shift(@tz) |> DateTime.to_date()
    assert Enum.any?(s.people, &(&1.user_id == builder.id))
    assert s.connections.total == 3
  end

  test "an empty audit log" do
    Repo.query!("SET LOCAL switchboard.audit_prune = 'on'")
    Repo.delete_all(Event)
    s = Stats.compute(:launch, [], @tz)
    assert s.headline == nil
    assert s.daily == []
  end

  test "client labels" do
    assert Stats.client_label("https://claude.ai/oauth/claude-code-client-metadata Claude Code") ==
             "Claude Code"

    assert Stats.client_label("https://chatgpt.com/oauth/codex/client.json Codex") == "Codex"
    assert Stats.client_label(" Zed on my laptop") == "laptop"
    assert Stats.client_label(nil) == "Unknown"
  end
end
