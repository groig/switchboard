defmodule SwitchboardWeb.ProfileActivityLiveTest do
  use SwitchboardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Switchboard.Scope

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  test "profile saves language and time zone; the UI follows the language", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/profile")

    view
    |> form("#profile-form", user: %{locale: "en", time_zone: "America/Havana", theme: "dark"})
    |> render_submit()

    user = Switchboard.Accounts.get_user!(user.id)
    assert {user.locale, user.time_zone, user.theme} == {"en", "America/Havana", "dark"}

    {:ok, _view, html} = live(conn, ~p"/profile")
    assert html =~ "Preferences"

    view
    |> form("#profile-form", user: %{locale: "es", time_zone: "Europe/Madrid", theme: "system"})
    |> render_submit()

    {:ok, _view, html} = live(conn, ~p"/profile")
    assert html =~ "Preferencias"
  end

  test "an unknown time zone is refused", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/profile")
    html = render_change(view, "validate", %{"user" => %{"time_zone" => "Mars/Olympus"}})
    assert html =~ "time zone" or html =~ "zona horaria"
  end

  test "my activity shows only my own rows", %{conn: conn, user: user} do
    Switchboard.Audit.log_web(Scope.for_user(user), "connection.linked", %{system: "plane"})
    other = user_fixture()
    Switchboard.Audit.log_web(Scope.for_user(other), "connection.linked", %{system: "argus"})

    {:ok, _view, html} = live(conn, ~p"/activity")
    assert html =~ "system=plane"
    refute html =~ "system=argus"
  end
end
