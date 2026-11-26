defmodule SwitchboardWeb.PageControllerTest do
  use SwitchboardWeb.ConnCase, async: true

  test "signed out, / offers to sign in with Forgejo", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ ~s(id="sign-in")
    assert html =~ ~s(href="/auth/forgejo")
  end

  test "signed in, / goes to Get started until an agent made a successful call", %{conn: conn} do
    user = user_fixture()
    assert conn |> log_in_user(user) |> get(~p"/") |> redirected_to() == ~p"/start"

    # A failed call or a web action doesn't count.
    scope = Switchboard.Scope.for_user(user, client_name: "Claude Code")
    Switchboard.Audit.log_tool(scope, "my_work", %{}, outcome: "error")
    Switchboard.Audit.log_web(scope, "connection.linked", %{system: "plane"})
    assert build_conn() |> log_in_user(user) |> get(~p"/") |> redirected_to() == ~p"/start"

    Switchboard.Audit.log_tool(scope, "whoami", %{}, outcome: "ok")
    assert build_conn() |> log_in_user(user) |> get(~p"/") |> redirected_to() == ~p"/connections"
  end

  test "a stale session (revoked by an admin) is signed out", %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(user_id: user.id, session_version: 0)
      |> get(~p"/connections")

    assert redirected_to(conn) == ~p"/"
  end
end
