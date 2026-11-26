defmodule SwitchboardWeb.WatchesLiveTest do
  use SwitchboardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Switchboard.{Controls, Repo}
  alias Switchboard.Watches.Watch

  defp watch(user, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Watch{
          user_id: user.id,
          kind: "ci",
          target: %{"repo" => "demo/app", "pr" => 42},
          subject: "demo/app",
          options: %{"next_run" => true},
          expires_at: DateTime.add(DateTime.utc_now(:second), 3600)
        },
        attrs
      )
    )
  end

  test "lists the person's own watches and cancels one (audited)", %{conn: conn} do
    user = user_fixture()
    other = user_fixture()
    mine = watch(user)

    ended =
      watch(user, %{
        status: "fired",
        end_reason: "notified",
        ended_at: DateTime.utc_now(:second),
        target: %{"id" => "DEMO-12"},
        kind: "task",
        subject: "DEMO-12"
      })

    theirs = watch(other)

    {:ok, view, _} = live(log_in_user(conn, user), ~p"/watches")
    assert has_element?(view, "#watch-#{mine.id}")
    assert has_element?(view, "#watch-#{ended.id}")
    refute has_element?(view, "#watch-#{theirs.id}")
    refute has_element?(view, "#cancel-watch-#{ended.id}")

    view |> element("#cancel-watch-#{mine.id}") |> render_click()
    assert Repo.get!(Watch, mine.id).status == "cancelled"
    refute has_element?(view, "#cancel-watch-#{mine.id}")

    assert [%{action: "watch.cancelled"}] =
             Switchboard.Audit.list(%{user_id: user.id, action: "watch.cancelled"})

    # A forged event for someone else's watch changes nothing.
    render_click(view, "cancel", %{"id" => theirs.id})
    assert Repo.get!(Watch, theirs.id).status == "active"
  end

  test "empty state and the paused banner", %{conn: conn} do
    user = user_fixture()
    admin = user_fixture() |> Ecto.Changeset.change(admin: true) |> Repo.update!()
    {:ok, view, _} = live(log_in_user(conn, user), ~p"/watches")
    assert render(view) =~ "No watches" or render(view) =~ "Sin avisos"
    refute has_element?(view, "#watches-paused")

    {:ok, _} = Controls.update_global(Switchboard.Scope.for_user(admin), %{watches_paused: true})
    {:ok, view, _} = live(log_in_user(build_conn(), user), ~p"/watches")
    assert has_element?(view, "#watches-paused")
  end

  test "admin: the pause switch and active watches per person", %{conn: conn} do
    admin = user_fixture() |> Ecto.Changeset.change(admin: true) |> Repo.update!()
    user = user_fixture()
    watch(user)
    conn = log_in_user(conn, admin)

    {:ok, view, _} = live(conn, ~p"/admin")
    view |> form("#global-form", global: %{watches_paused: "true"}) |> render_submit()
    assert Controls.watches_paused?()

    {:ok, view, _} = live(conn, ~p"/admin/people")
    assert view |> element("#user-#{user.id}") |> render() =~ ~r/>\s*1\s*</
  end
end
