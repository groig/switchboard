defmodule SwitchboardWeb.ClientsLiveTest do
  use SwitchboardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Switchboard.{OAuth, PersonalTokens, Scope}

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  defp dom(key), do: SwitchboardWeb.ClientsLive.group_dom_id(key)

  test "shows connected clients and revokes one", %{conn: conn, user: user} do
    {^user, _client, %{"access_token" => access}} = token_fixture(user)
    [_grant] = OAuth.list_grants(user)
    id = dom("name:Test client")

    {:ok, view, _html} = live(conn, ~p"/clients")
    assert has_element?(view, "#grant-group-#{id}")
    refute has_element?(view, "#remove-stale-#{id}")

    view |> element("#revoke-group-#{id}") |> render_click()
    refute has_element?(view, "#grant-group-#{id}")
    assert {:error, :invalid_token} = OAuth.verify_access_token(access)
    assert [%{action: "client.revoked"} | _] = Switchboard.Audit.list(%{user_id: user.id})
  end

  test "collapses repeated registrations of one client and removes the stale ones",
       %{conn: conn, user: user} do
    {_, _, %{"access_token" => old}} = token_fixture(user)
    {_, _, %{"access_token" => newer}} = token_fixture(user)
    [latest, _stale] = OAuth.list_grants(user)
    # The newest one is the one in use.
    Switchboard.Repo.update!(
      Ecto.Changeset.change(latest, last_used_at: DateTime.add(DateTime.utc_now(:second), 60))
    )

    id = dom("name:Test client")

    {:ok, view, _html} = live(conn, ~p"/clients")
    assert view |> element("#grant-count-#{id}") |> render() =~ ~r/2 (connections|conexiones)/

    view |> element("#remove-stale-#{id}") |> render_click()
    assert has_element?(view, "#grant-group-#{id}")
    refute has_element?(view, "#grant-count-#{id}")
    assert [%{id: kept}] = OAuth.list_grants(user)
    assert kept == latest.id

    alive = Enum.filter([old, newer], &match?({:ok, _, _}, OAuth.verify_access_token(&1)))
    assert length(alive) == 1

    assert [%{action: "client.removed_stale", args: %{"count" => 1}} | _] =
             Switchboard.Audit.list(%{user_id: user.id})
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
