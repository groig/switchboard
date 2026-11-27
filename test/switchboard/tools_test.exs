defmodule Switchboard.ToolsTest do
  # The policy matrix for Tools.run/3: kill switches, read-only mode, rate limits, audit.
  use Switchboard.DataCase, async: true

  import Switchboard.OAuthFixtures

  alias Switchboard.Audit.Event
  alias Switchboard.{Controls, RateLimit, Scope, Tools}

  setup do
    user = user_fixture()
    admin = user_fixture(%{username: "boss#{System.unique_integer([:positive])}"})
    admin = %{admin | admin: true}

    {:ok,
     scope: Scope.for_user(user, client_name: "Claude Code", ip: "203.0.113.9"),
     admin: Scope.for_user(admin, via: :browser)}
  end

  defp last_event(user),
    do: Repo.one(from e in Event, where: e.user_id == ^user.id, order_by: [desc: e.at], limit: 1)

  test "a call runs and is audited with outcome, size, upstreams and redacted args", %{
    scope: scope
  } do
    assert {:ok, "noted: hello"} =
             Tools.run(scope, "test_note", %{"text" => "hello", "secret" => "s3"})

    event = last_event(scope.user)
    assert %{kind: "mcp", action: "test_note", outcome: "ok", client_name: "Claude Code"} = event
    assert event.result_bytes == byte_size("noted: hello")
    assert event.upstreams == ["plane"]
    assert event.ip == "203.0.113.9"
    # `text` is flagged by the tool, `secret` matches the credential pattern.
    assert event.args == %{"text" => "[redacted]", "secret" => "[redacted]"}
  end

  test "argument errors are refused and audited", %{scope: scope} do
    assert {:error, "Missing arguments: text. test_note takes:" <> _} =
             Tools.run(scope, "test_note", %{})

    assert {:error, "Unknown arguments: x. " <> _} =
             Tools.run(scope, "test_note", %{"text" => "a", "x" => 1})

    assert %{outcome: "error"} = last_event(scope.user)
  end

  @tag :capture_log
  test "a crashing tool becomes an error result", %{scope: scope} do
    assert {:error, message} = Tools.run(scope, "test_note", %{"text" => "crash"})
    assert message =~ "failed unexpectedly"
  end

  test "the kill switch refuses the tool and hides it", %{scope: scope, admin: admin} do
    {:ok, _} = Controls.update_tool(admin, "test_note", %{enabled: false})

    assert {:error, msg} = Tools.run(scope, "test_note", %{"text" => "a"})
    assert msg =~ "turned off"
    assert %{outcome: "disabled"} = last_event(scope.user)
    refute Switchboard.TestTools.Note in Tools.available(scope)

    :ok = Controls.reset_tool(admin, "test_note")
    assert {:ok, _} = Tools.run(scope, "test_note", %{"text" => "a"})
  end

  test "read-only mode refuses write tools but not reads", %{scope: scope, admin: admin} do
    {:ok, _} = Controls.update_global(admin, %{read_only: true})

    assert {:error, msg} = Tools.run(scope, "test_note", %{"text" => "a"})
    assert msg =~ "read-only"
    assert {:ok, _} = Tools.run(scope, "whoami", %{})
    refute Switchboard.TestTools.Note in Tools.available(scope)
    assert Switchboard.Tools.Whoami in Tools.available(scope)
  end

  test "the maintenance message is prepended to results", %{scope: scope, admin: admin} do
    {:ok, _} = Controls.update_global(admin, %{maintenance_message: "Plane upgrade at 18:00"})

    assert {:ok, "> **Maintenance:** Plane upgrade at 18:00\n\nnoted: a"} =
             Tools.run(scope, "test_note", %{"text" => "a"})
  end

  test "rate limits are per person and tool", %{scope: scope, admin: admin} do
    {:ok, _} = Controls.update_tool(admin, "test_note", %{rate_limit: 2})

    assert {:ok, _} = Tools.run(scope, "test_note", %{"text" => "1"})
    assert {:ok, _} = Tools.run(scope, "test_note", %{"text" => "2"})
    assert {:error, msg} = Tools.run(scope, "test_note", %{"text" => "3"})
    assert msg =~ "Rate limit"
    assert %{outcome: "rate_limited"} = last_event(scope.user)

    # Another tool, and another person, are unaffected.
    assert {:ok, _} = Tools.run(scope, "whoami", %{})
    other = Scope.for_user(user_fixture())
    assert {:ok, _} = Tools.run(other, "test_note", %{"text" => "1"})
  end

  test "write tools default to a lower limit than reads" do
    assert Controls.default_rate_limit(Switchboard.TestTools.Note) <
             Controls.default_rate_limit(Switchboard.Tools.Whoami)
  end

  describe "RateLimit" do
    test "a bucket allows bursts up to its capacity, then refills over time" do
      key = {:test, System.unique_integer()}
      assert :ok = RateLimit.take(key, 2, 1_000)
      assert :ok = RateLimit.take(key, 2, 1_000)
      assert {:error, ms} = RateLimit.take(key, 2, 1_000)
      assert ms > 0 and ms <= 500
    end

    test "concurrent takes never exceed the capacity" do
      key = {:test, System.unique_integer()}

      results =
        1..200
        |> Task.async_stream(fn _ -> RateLimit.take(key, 50, 3_600_000) end, max_concurrency: 50)
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.count(results, &(&1 == :ok)) == 50
    end
  end
end
