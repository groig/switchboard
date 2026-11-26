defmodule SwitchboardWeb.PageControllerTest do
  use SwitchboardWeb.ConnCase, async: true

  test "signed out, / offers to sign in with Forgejo", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ ~s(id="sign-in")
    assert html =~ ~s(href="/auth/forgejo")
  end

  test "signed in, / goes to Connections", %{conn: conn} do
    conn = conn |> log_in_user(user_fixture()) |> get(~p"/")
    assert redirected_to(conn) == ~p"/connections"
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
