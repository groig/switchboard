defmodule Switchboard.AuditTest do
  use Switchboard.DataCase, async: true

  import Switchboard.OAuthFixtures

  alias Switchboard.{Audit, Scope}
  alias Switchboard.Audit.Event

  test "redact/2 hides credential-like keys and flagged args, and truncates" do
    args = %{
      "api_key" => "k",
      "Authorization" => "Bearer x",
      "nested" => %{"refresh_token" => "r", "ok" => "fine"},
      "body" => String.duplicate("a", 500),
      "list" => Enum.to_list(1..30),
      "note" => "private"
    }

    redacted = Audit.redact(args, ["note"])

    assert redacted["api_key"] == "[redacted]"
    assert redacted["Authorization"] == "[redacted]"
    assert redacted["nested"] == %{"refresh_token" => "[redacted]", "ok" => "fine"}
    assert redacted["note"] == "[redacted]"
    assert String.length(redacted["body"]) == 201
    assert length(redacted["list"]) == 21
  end

  test "oversized arguments are replaced by a note" do
    args = Map.new(1..100, &{"k#{&1}", String.duplicate("x", 150)})
    assert Audit.redact(args) == %{"_truncated" => "arguments too large to store"}
  end

  test "rows are append-only" do
    scope = Scope.for_user(user_fixture())
    event = Audit.log_web(scope, "login")

    assert_raise Postgrex.Error, ~r/append-only/, fn ->
      event |> Ecto.Changeset.change(outcome: "error") |> Repo.update!()
    end

    assert_raise Postgrex.Error, ~r/append-only/, fn -> Repo.delete!(event) end
  end

  test "prune/1 removes only rows older than the retention" do
    scope = Scope.for_user(user_fixture())
    old = Audit.log_web(scope, "login")
    new = Audit.log_web(scope, "logout")

    # Pretend it is 181 days later for the first row only.
    later = DateTime.add(old.at, Audit.retention_days() * 86_400 + 1)
    Repo.query!("ALTER TABLE audit_events DISABLE TRIGGER audit_events_append_only")
    Repo.update_all(from(e in Event, where: e.id == ^new.id), set: [at: later])
    Repo.query!("ALTER TABLE audit_events ENABLE TRIGGER audit_events_append_only")

    assert Audit.prune(DateTime.add(later, 1)) == 1
    refute Repo.get(Event, old.id)
    assert Repo.get(Event, new.id)
  end

  test "list_mine/2 returns only the person's rows" do
    mine = Scope.for_user(user_fixture())
    theirs = Scope.for_user(user_fixture())
    Audit.log_web(mine, "login")
    Audit.log_web(theirs, "login")

    assert [%{user_id: id}] = Audit.list_mine(mine)
    assert id == mine.user.id
  end
end
