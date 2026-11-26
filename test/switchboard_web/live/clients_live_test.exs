defmodule SwitchboardWeb.ClientsLiveTest do
  use SwitchboardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Switchboard.{OAuth, PersonalTokens, Scope}

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  test "shows connected clients and revokes one", %{conn: conn, user: user} do
    {^user, _client, %{"access_token" => access}} = token_fixture(user)
    [grant] = OAuth.list_grants(user)

    {:ok, view, _html} = live(conn, ~p"/clients")
    assert has_element?(view, "#grant-#{grant.id}")

    view |> element("#revoke-grant-#{grant.id}") |> render_click()
    refute has_element?(view, "#grant-#{grant.id}")
    assert {:error, :invalid_token} = OAuth.verify_access_token(access)
  end

  test "creates a personal token, shows it once, then revokes it", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/clients")

    view |> element("#new-token") |> render_click()
    view |> form("#token-form", token: %{name: "Zed", expires: "30"}) |> render_submit()

    token =
      view |> element("#token-value") |> render() |> then(&Regex.run(~r/sb_[\w-]+/, &1)) |> hd()

    assert {:ok, _, _} = PersonalTokens.verify(token)

    # Closing the dialog forgets it.
    render_hook(view, "close_token", %{})
    refute render(view) =~ token

    [record] = PersonalTokens.list(Scope.for_user(user))
    view |> element("#revoke-token-#{record.id}") |> render_click()
    assert {:error, :invalid_token} = PersonalTokens.verify(token)
  end
end
