defmodule SwitchboardWeb.AdminLiveTest do
  use SwitchboardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Switchboard.{Accounts, Controls, OAuth, Scope}

  setup %{conn: conn} do
    admin = user_fixture()
    admin = admin |> Ecto.Changeset.change(admin: true) |> Switchboard.Repo.update!()
    {:ok, conn: log_in_user(conn, admin), admin: admin}
  end

  test "non-admins get a 404 and never mount admin pages", %{conn: _conn} do
    conn = log_in_user(build_conn(), user_fixture())

    for path <- ~w(/admin /admin/audit /admin/people /admin/health /admin/onboarding) do
      assert conn |> get(path) |> response(404)
    end
  end

  test "onboarding: each person's steps, read-only", %{conn: conn} do
    pat = user_fixture()
    ana = user_fixture()

    Switchboard.Audit.log_tool(Scope.for_user(ana, client_name: "Codex"), "whoami", %{},
      outcome: "ok"
    )

    {:ok, view, _html} = live(conn, ~p"/admin/onboarding")
    assert has_element?(view, "#onboarding-#{pat.id}")
    refute has_element?(view, "#onboarding-#{pat.id}", "Codex")
    assert has_element?(view, "#onboarding-#{ana.id}", "Codex")
    assert has_element?(view, "#onboarding-#{ana.id}", "1/5")
    refute has_element?(view, "#onboarding button")
  end

  test "controls: read-only mode, maintenance message and tool switches", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin")

    view
    |> form("#global-form", global: %{read_only: "true", maintenance_message: "Back at 18:00"})
    |> render_submit()

    assert Controls.read_only?()
    assert Controls.maintenance_message() == "Back at 18:00"
    assert has_element?(view, "#maintenance-banner")

    view |> element("#toggle-whoami") |> render_click()
    refute Controls.tool_enabled?("whoami")

    view |> form("#limit-whoami", %{"tool" => "whoami", "rate_limit" => "5"}) |> render_submit()
    assert Controls.rate_limit(Switchboard.Tools.Whoami) == 5
  end

  test "controls: workflows have their own switches and limits", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin")

    assert has_element?(view, "#workflow-controls")
    assert has_element?(view, "#toggle-workflow-standup")

    view |> element("#toggle-workflow-standup") |> render_click()
    refute Controls.tool_enabled?("workflow:standup")
    assert Controls.tool_enabled?("workflow:next")

    view
    |> form("#limit-workflow-next", %{"tool" => "workflow:next", "rate_limit" => "3"})
    |> render_submit()

    assert Controls.rate_limit(Switchboard.Workflows.Next) == 3

    assert has_element?(
             view,
             ~s(#workflow-controls button[phx-value-tool="workflow:next"][phx-click="reset_tool"])
           )

    assert [%{action: "admin.tool_updated", args: %{"tool" => "workflow:standup"}} | _] =
             Switchboard.Audit.list(%{kind: "web"}) |> Enum.reverse()
  end

  test "audit log filters by person", %{conn: conn, admin: admin} do
    other = user_fixture()
    Switchboard.Audit.log_web(Scope.for_user(other), "login")
    Switchboard.Audit.log_web(Scope.for_user(admin), "logout")

    {:ok, view, _html} = live(conn, ~p"/admin/audit?username=#{other.username}")

    rows =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#audit li[id^='events-']")

    assert Enum.count(rows) == 1
    assert LazyHTML.text(rows) =~ other.username
  end

  test "people: revoke all disconnects clients and signs the person out", %{conn: conn} do
    {person, _client, %{"access_token" => access}} = token_fixture()

    {:ok, view, _html} = live(conn, ~p"/admin/people")
    view |> element("#revoke-all-#{person.id}") |> render_click()

    assert {:error, :invalid_token} = OAuth.verify_access_token(access)
    assert Accounts.get_user!(person.id).session_version == person.session_version + 1
  end
end
