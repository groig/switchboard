defmodule SwitchboardWeb.ConnectionsLiveTest do
  use SwitchboardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    user = user_fixture(%{email: "ana@example.com"})
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  test "requires a session" do
    assert {:error, {:redirect, %{to: "/"}}} = live(build_conn(), ~p"/connections")
  end

  test "lists every system, with Forgejo already connected", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/connections")

    for system <- ~w(forgejo plane argus outline rocketchat),
        do: assert(has_element?(view, "#connection-#{system}"))

    assert has_element?(view, "#test-forgejo")
    assert has_element?(view, "#link-plane")
    refute has_element?(view, "#link-forgejo")
  end

  test "linking a key tests it and never echoes it back", %{conn: conn} do
    Req.Test.stub(Switchboard.Upstreams, fn conn ->
      case Plug.Conn.get_req_header(conn, "x-api-key") do
        ["good-key"] ->
          Req.Test.json(conn, %{"email" => "someone.else@example.com", "display_name" => "x"})

        _ ->
          conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{})
      end
    end)

    {:ok, view, _html} = live(conn, ~p"/connections")
    view |> element("#link-plane") |> render_click()
    assert has_element?(view, "#link-form")
    assert has_element?(view, "#key-url")

    html = view |> form("#link-form", credential: %{token: "bad-key"}) |> render_submit()
    assert has_element?(view, "#link-error")
    refute html =~ "bad-key"

    view |> form("#link-form", credential: %{token: "good-key"}) |> render_submit()
    refute has_element?(view, "#link-form")
    assert has_element?(view, "#test-plane")
    # The key belongs to someone else: warn.
    assert has_element?(view, "#mismatch-plane")
    refute render(view) =~ "good-key"
  end

  test "testing and removing a key", %{conn: conn, user: user} do
    Req.Test.stub(Switchboard.Upstreams, fn conn ->
      Req.Test.json(conn, %{"email" => "ana@example.com", "display_name" => "ana"})
    end)

    {:ok, _} =
      Switchboard.Connections.link(Switchboard.Scope.for_user(user), "plane", %{"token" => "k"})

    {:ok, view, _html} = live(conn, ~p"/connections")
    Req.Test.allow(Switchboard.Upstreams, self(), view.pid)

    view |> element("#test-plane") |> render_click()
    assert render_async(view) =~ "flash"

    view |> element("#remove-plane") |> render_click()
    assert has_element?(view, "#link-plane")
  end
end
