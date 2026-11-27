defmodule SwitchboardWeb.GitHubAuthControllerTest do
  # Connect GitHub (OAuth App): state check, the callback storing the token, unlink revoking it.
  use SwitchboardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Switchboard.UpstreamStubs, only: [stub: 0, stub: 1, link_github: 1]

  alias Switchboard.{Audit, Connections, Scope}

  setup %{conn: conn} do
    user = english_user()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  defp english_user,
    do: user_fixture() |> Ecto.Changeset.change(locale: "en") |> Switchboard.Repo.update!()

  defp start_connect(conn) do
    conn = get(conn, ~p"/auth/github")
    location = redirected_to(conn, 302)
    assert location =~ "http://github.test/login/oauth/authorize?"
    query = URI.decode_query(URI.parse(location).query)

    assert %{
             "client_id" => "gh-client",
             "scope" => "repo",
             "redirect_uri" => "http://localhost:4002/auth/github/callback",
             "code_challenge_method" => "S256"
           } = query

    {conn, query["state"]}
  end

  defp recycle_session(conn),
    do: conn |> recycle() |> Map.put(:secret_key_base, conn.secret_key_base)

  test "requires a session" do
    assert build_conn() |> get(~p"/auth/github") |> redirected_to() == ~p"/"
  end

  test "the callback checks state, stores the token encrypted and audits the link", %{
    conn: conn,
    user: user
  } do
    stub()
    {conn, state} = start_connect(conn)

    conn = get(recycle_session(conn), ~p"/auth/github/callback?code=good&state=#{state}")
    assert redirected_to(conn) == "/connections#connection-github"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "GitHub connected as @ana-gh"

    assert_received {:github_token_exchange, form}

    assert %{"code" => "good", "client_secret" => "gh-secret", "code_verifier" => verifier} =
             form

    assert byte_size(verifier) >= 43

    connection = Connections.get(user, "github")
    assert connection.status == "ok"
    assert connection.identity["username"] == "ana-gh"
    assert connection.identity_matches
    assert {:ok, %{"access_token" => "gho_new-token"}} = Connections.credential(user, "github")

    # Encrypted at rest.
    [[raw]] =
      Switchboard.Repo.query!(
        "SELECT secret FROM connections WHERE user_id = $1 AND system = 'github'",
        [Ecto.UUID.dump!(user.id)]
      ).rows

    refute raw =~ "gho_new-token"

    assert [%{action: "connection.linked", args: %{"system" => "github"}} | _] =
             Audit.list(%{user_id: user.id})
  end

  test "a forged or missing state is refused before any exchange", %{conn: conn, user: user} do
    stub()
    {conn, _state} = start_connect(conn)

    conn = get(recycle_session(conn), ~p"/auth/github/callback?code=good&state=forged")
    assert redirected_to(conn) == "/connections#connection-github"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "expired or did not come from"

    # No session state at all (a callback opened in another browser).
    conn =
      build_conn()
      |> log_in_user(user)
      |> get(~p"/auth/github/callback?code=good&state=anything")

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "expired"

    refute_received {:github_token_exchange, _}
    refute Connections.get(user, "github")
  end

  test "a state is single use", %{conn: conn, user: user} do
    stub()
    {conn, state} = start_connect(conn)
    conn = get(recycle_session(conn), ~p"/auth/github/callback?code=good&state=#{state}")
    assert Connections.get(user, "github")
    assert_received {:github_token_exchange, _}

    conn = get(recycle_session(conn), ~p"/auth/github/callback?code=good&state=#{state}")
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "expired"
    refute_received {:github_token_exchange, _}
  end

  @tag :capture_log
  test "a cancelled consent or a bad code stores nothing", %{conn: conn, user: user} do
    stub()
    {conn, state} = start_connect(conn)

    conn =
      get(recycle_session(conn), ~p"/auth/github/callback?error=access_denied&state=#{state}")

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "cancelled"

    {conn, state} = start_connect(recycle_session(conn))
    conn = get(recycle_session(conn), ~p"/auth/github/callback?code=bad-code&state=#{state}")
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Connecting GitHub failed"
    refute Connections.get(user, "github")
  end

  test "a pasted token is refused: GitHub links only through the OAuth flow", %{user: user} do
    assert {:error, :not_linkable} =
             Connections.link(Scope.for_user(user), "github", %{"token" => "x"})
  end

  test "unlink revokes the grant in GitHub, then removes the row", %{user: user} do
    stub()
    link_github(user)
    scope = Scope.for_user(user)

    assert :ok = Connections.unlink(scope, "github")

    assert_received {:upstream_write, "api.github.test", "DELETE",
                     "/applications/gh-client/grant", %{"authorization" => "Basic " <> basic},
                     %{"access_token" => token}}

    assert Base.decode64!(basic) == "gh-client:gh-secret"
    assert token == "gho_test-#{user.id}"
    refute Connections.get(user, "github")

    assert [
             %{action: "connection.unlinked", args: %{"system" => "github", "revoked" => true}}
             | _
           ] =
             Audit.list(%{user_id: user.id})
  end

  @tag :capture_log
  test "unlink still removes the row when GitHub can't be reached", %{user: user} do
    stub(%{"api.github.test" => {:status, 503}})
    link_github(user)

    assert {:ok, :not_revoked} = Connections.unlink(Scope.for_user(user), "github")
    refute Connections.get(user, "github")
  end

  describe "the Connections page" do
    test "Connect GitHub when not linked; Disconnect and org access when linked", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/connections")
      assert has_element?(view, "#connect-github[href='/auth/github']")
      refute has_element?(view, "#link-github")
      refute has_element?(view, "#github-org-access")

      stub()
      link_github(user)
      {:ok, view, _html} = live(conn, ~p"/connections")
      refute has_element?(view, "#connect-github")
      assert has_element?(view, "#test-github")
      assert has_element?(view, "#github-org-access[href$='/applications/gh-client']")
      refute has_element?(view, "#mismatch-github")

      view |> element("#remove-github") |> render_click()
      assert render(view) =~ "access was revoked in GitHub"
      assert has_element?(view, "#connect-github")
      assert_received {:upstream_write, "api.github.test", "DELETE", _, _, _}
    end

    test "testing a GitHub link keeps it as the person's own", %{conn: conn, user: user} do
      stub()
      link_github(user)
      {:ok, view, _html} = live(conn, ~p"/connections")
      Req.Test.allow(Switchboard.Upstreams, self(), view.pid)
      view |> element("#test-github") |> render_click()
      _ = render_async(view)
      assert Connections.get(user, "github").status == "ok"
      assert Connections.get(user, "github").identity_matches
    end
  end
end
