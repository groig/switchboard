defmodule SwitchboardWeb.AuthControllerTest do
  use SwitchboardWeb.ConnCase, async: true

  alias Switchboard.{Accounts, Connections}

  # Starts the sign-in, then returns {conn_with_session, state}.
  defp start_login(conn) do
    conn = get(conn, ~p"/auth/forgejo")
    location = redirected_to(conn, 302)
    assert location =~ "http://forgejo.test/login/oauth/authorize?"
    %{"state" => state, "scope" => scope} = URI.decode_query(URI.parse(location).query)
    assert scope =~ "read:user"
    {conn, state}
  end

  defp stub_login(orgs, opts \\ []) do
    Req.Test.stub(Switchboard.Forgejo, fn conn ->
      case conn.request_path do
        "/login/oauth/access_token" ->
          Req.Test.json(conn, %{
            "access_token" => "fg-access",
            "refresh_token" => "fg-refresh",
            "expires_in" => 3600
          })

        "/api/v1/user" ->
          Req.Test.json(conn, %{
            "id" => 4242,
            "login" => "ana",
            "email" => "ana@example.com",
            "full_name" => "Ana García",
            "active" => Keyword.get(opts, :active, true)
          })

        "/api/v1/user/orgs" ->
          Req.Test.json(conn, Enum.map(orgs, &%{"username" => &1}))
      end
    end)
  end

  test "a member of an allowed org signs in; the Forgejo token is stored encrypted", %{conn: conn} do
    stub_login(["acme"])
    {conn, state} = start_login(conn)

    conn = get(recycle_session(conn), ~p"/auth/forgejo/callback?code=abc&state=#{state}")
    assert redirected_to(conn) == ~p"/connections"

    user = Switchboard.Repo.get_by!(Accounts.User, username: "ana")
    assert {:ok, "fg-access"} = Connections.forgejo_token(user)
    assert [%{action: "login"}] = Switchboard.Audit.list(%{user_id: user.id})
  end

  test "people outside the allowed orgs, and deactivated accounts, are refused", %{conn: conn} do
    for {orgs, opts} <- [{["Other"], []}, {["Acme"], [active: false]}] do
      stub_login(orgs, opts)
      {conn, state} = start_login(conn)
      conn = get(recycle_session(conn), ~p"/auth/forgejo/callback?code=abc&state=#{state}")
      assert html_response(conn, 403) =~ "oauth-error"
    end

    refute Switchboard.Repo.get_by(Accounts.User, username: "ana")
  end

  test "a state mismatch is refused", %{conn: conn} do
    {conn, _state} = start_login(conn)
    conn = get(recycle_session(conn), ~p"/auth/forgejo/callback?code=abc&state=forged")
    assert html_response(conn, 400) =~ "oauth-error"
  end

  test "logging out ends the session", %{conn: conn} do
    conn = conn |> log_in_user(user_fixture()) |> delete(~p"/auth/logout")
    assert redirected_to(conn) == ~p"/"
    assert get(recycle(conn), ~p"/connections") |> redirected_to() == ~p"/"
  end

  defp recycle_session(conn),
    do: conn |> recycle() |> Map.put(:secret_key_base, conn.secret_key_base)
end
