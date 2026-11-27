defmodule Switchboard.GitHubUnconfiguredTest do
  # Without GITHUB_CLIENT_ID / GITHUB_CLIENT_SECRET: no GitHub connection, owner/repo is Forgejo,
  # and an explicit GitHub repo says why it can't work. Changes global config: not async.
  use SwitchboardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Switchboard.UpstreamStubs, only: [stub: 0]

  alias Switchboard.{Onboarding, Repos, Scope, Tools, Upstreams}

  setup do
    previous = Application.get_env(:switchboard, Switchboard.GitHub)
    Application.put_env(:switchboard, Switchboard.GitHub, owners: ["example-org"])
    on_exit(fn -> Application.put_env(:switchboard, Switchboard.GitHub, previous) end)
    :ok
  end

  test "GitHub is hidden and owner/repo always means Forgejo", %{conn: conn} do
    refute "github" in Upstreams.systems()
    assert {:ok, %{host: :forgejo}} = Repos.resolve("example-org/example-repo")

    assert {:error, msg} = Repos.resolve("github:example-org/example-repo")
    assert msg =~ "GitHub is not set up on this Switchboard"
    assert msg =~ "GITHUB_CLIENT_ID"

    user = user_fixture() |> Ecto.Changeset.change(locale: "en") |> Switchboard.Repo.update!()
    refute Enum.any?(Onboarding.accounts(Scope.for_user(user)), &(&1.system == "github"))

    conn = log_in_user(conn, user)
    {:ok, view, _html} = live(conn, ~p"/connections")
    refute has_element?(view, "#connection-github")

    conn = get(conn, ~p"/auth/github")
    assert redirected_to(conn) == "/connections#connection-github"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not set up"
  end

  test "a Forgejo 404 doesn't suggest GitHub" do
    Req.Test.stub(Switchboard.Upstreams, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
    end)

    scope = Scope.for_user(user_fixture())

    assert {:error, msg} =
             Tools.run(scope, "repo_search_prs", %{"repo" => "other-org/other-repo"})

    assert msg == "`other-org/other-repo` isn't on Forgejo, or you can't see it there."
    _ = stub()
  end
end
