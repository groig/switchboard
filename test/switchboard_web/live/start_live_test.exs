defmodule SwitchboardWeb.StartLiveTest do
  # The Get started page against synthetic upstreams (no real data).
  use SwitchboardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Switchboard.Connections.Connection
  alias Switchboard.{Audit, Repo, Scope, UpstreamStubs, Workflows}

  defp en_user, do: user_fixture() |> Ecto.Changeset.change(locale: "en") |> Repo.update!()

  defp claude(user), do: Scope.for_user(user, client_name: "Claude Code")

  defp done?(view, id), do: has_element?(view, "##{id}[data-done=true]")

  test "a new person: nothing done, Forgejo linked, prompts greyed out until linked", %{
    conn: conn
  } do
    UpstreamStubs.stub()
    user = en_user()
    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/start")

    for step <- ~w(step-agent step-accounts step-prompts step-commands),
        do: refute(done?(view, step))

    assert has_element?(view, "#account-forgejo[data-status=linked]")
    assert has_element?(view, "#account-plane[data-status=missing]")
    assert has_element?(view, "#key-link-plane[href$='/settings/profile/api-tokens']")
    assert has_element?(view, "#key-link-outline[href$='/settings/api-and-access']")
    assert has_element?(view, "#key-link-argus[href$='/settings#api-tokens']")
    assert has_element?(view, "#key-link-rocketchat[href$='/account/tokens']")
    assert has_element?(view, "#link-plane[href='/connections#connection-plane']")

    # Greyed out with a hint to link the missing system; ready ones can be copied.
    assert has_element?(view, "#prompt-pickup[data-ready=false]")

    assert has_element?(
             view,
             "#prompt-pickup-hint a[href='/connections#connection-plane']",
             "Link Plane to try this"
           )

    refute has_element?(view, "#prompt-pickup-copy")
    assert has_element?(view, "#prompt-ci[data-ready=true]")
    assert has_element?(view, "#prompt-ci-copy")
    assert has_element?(view, "#tried-count", "0 of 12 tried")
  end

  test "the connect commands use the public URL, per client tab", %{conn: conn} do
    UpstreamStubs.stub()
    {:ok, view, _html} = live(log_in_user(conn, en_user()), ~p"/start")
    url = Switchboard.OAuth.resource()

    assert has_element?(
             view,
             "#connect-commands",
             "claude mcp add --transport http switchboard #{url}"
           )

    assert has_element?(view, "#connect-commands", "claude mcp login switchboard")

    view |> element("#tab-codex") |> render_click()
    assert has_element?(view, "#connect-commands", "codex mcp add switchboard --url #{url}")
    refute has_element?(view, "#connect-commands", "claude mcp")
  end

  test "done states: agent, accounts, prompts and commands, ticked off live", %{conn: conn} do
    UpstreamStubs.stub()
    user = en_user() |> UpstreamStubs.link_all()

    Repo.insert!(%Connection{
      user_id: user.id,
      system: "rocketchat",
      secret: %{"token" => "rc", "user_id" => "u1"},
      status: "ok"
    })

    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/start")
    assert done?(view, "step-accounts")
    assert has_element?(view, "#accounts-count", "5 of 5 linked")
    refute done?(view, "step-agent")

    # The agent's calls arrive while the page is open.
    Audit.log_tool(claude(user), "whoami", %{}, outcome: "ok")
    assert done?(view, "step-agent")
    assert has_element?(view, "#agent-done", "Claude Code called Switchboard")

    Audit.log_tool(claude(user), "workflow:next", %{}, outcome: "ok")
    Audit.log_tool(claude(user), "chat_inbox", %{}, outcome: "ok")
    assert has_element?(view, "#prompt-next[data-done=true]")
    assert has_element?(view, "#tried-count", "2 of 12 tried")
    refute done?(view, "step-prompts")
    assert done?(view, "step-commands")

    # A failed call doesn't count.
    Audit.log_tool(claude(user), "error_list", %{}, outcome: "error")
    refute has_element?(view, "#prompt-errors[data-done=true]")

    Audit.log_tool(claude(user), "error_list", %{}, outcome: "ok")
    assert done?(view, "step-prompts")
  end

  test "an account with a rejected key needs attention and keeps its prompts greyed", %{
    conn: conn
  } do
    UpstreamStubs.stub()
    user = en_user()

    Repo.insert!(%Connection{
      user_id: user.id,
      system: "argus",
      secret: %{"token" => "argus_key"},
      status: "rejected"
    })

    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/start")
    assert has_element?(view, "#account-argus[data-status=error]")
    assert has_element?(view, "#prompt-triage[data-ready=false]")
  end

  describe "personalized prompts" do
    test "a skeleton first, then one of their own tasks and a recent error", %{conn: conn} do
      UpstreamStubs.stub()
      user = en_user() |> UpstreamStubs.link_all()
      conn = log_in_user(conn, user)

      html = conn |> get(~p"/start") |> html_response(200)
      assert html =~ ~s(id="prompt-pickup-loading")

      {:ok, view, _html} = live(conn, ~p"/start")
      render_async(view)
      assert view |> element("#prompt-pickup-text") |> render() =~ ~r/Pick up DEMO-\d+/
      assert has_element?(view, "#prompt-triage-text", "Triage demo-api/7 and suggest a fix.")
    end

    test "failing upstreams fall back to placeholders", %{conn: conn} do
      UpstreamStubs.stub(%{"plane.test" => {:status, 500}, "argus.test" => :transport_error})
      user = en_user() |> UpstreamStubs.link_all()
      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/start")
      render_async(view)

      assert has_element?(view, "#prompt-pickup-text", "Pick up <task>")
      assert has_element?(view, "#prompt-triage-text", "Triage <error> and suggest a fix.")
    end

    test "missing connections: placeholders, and no upstream call", %{conn: conn} do
      test = self()

      Req.Test.stub(Switchboard.Upstreams, fn c ->
        send(test, {:upstream, c.host})
        Req.Test.json(c, %{})
      end)

      {:ok, view, _html} = live(log_in_user(conn, en_user()), ~p"/start")
      render_async(view)
      assert has_element?(view, "#prompt-handoff-text", "Hand off <task> to QA.")
      refute_received {:upstream, _}
    end
  end

  test "the commands section is generated from the workflow registry", %{conn: conn} do
    UpstreamStubs.stub()
    {:ok, view, _html} = live(log_in_user(conn, en_user()), ~p"/start")
    rows = view |> render() |> LazyHTML.from_document() |> LazyHTML.query("#commands tbody tr")
    assert Enum.count(rows) == length(Workflows.all())

    for mod <- Workflows.all() do
      assert has_element?(view, "#command-#{mod.name()}", mod.purpose())
      assert has_element?(view, "#command-#{mod.name()}", "/mcp__switchboard__#{mod.name()}")
      assert has_element?(view, "#command-#{mod.name()}", mod.example().says)
    end

    assert has_element?(view, "#command-pickup", "/mcp__switchboard__pickup DEMO-12")
  end

  test "the page is in Spanish for Spanish speakers", %{conn: conn} do
    UpstreamStubs.stub()
    user = user_fixture() |> Ecto.Changeset.change(locale: "es") |> Repo.update!()
    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/start")

    assert has_element?(view, "h1", "Primeros pasos")
    assert has_element?(view, "#command-standup", "Redactar tu standup")
  end

  describe "empty states point to Get started" do
    test "connections, activity and watches", %{conn: conn} do
      conn = log_in_user(conn, en_user())

      {:ok, view, _} = live(conn, ~p"/connections")
      assert has_element?(view, "#connections-start-link[href='/start']")

      {:ok, view, _} = live(conn, ~p"/activity")
      assert has_element?(view, "#activity-start[href='/start']")

      {:ok, view, _} = live(conn, ~p"/watches")
      assert has_element?(view, "#watches-start[href='/start']")
    end
  end
end
