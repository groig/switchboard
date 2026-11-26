defmodule SwitchboardWeb.AuthController do
  @moduledoc "Sign in with Forgejo."
  use SwitchboardWeb, :controller

  alias Switchboard.{Accounts, Audit, Connections, Scope}
  alias Switchboard.Forgejo.Login
  alias SwitchboardWeb.UserAuth

  require Logger

  def login(conn, _params) do
    state = random()
    verifier = random()

    conn
    |> put_session(:forgejo_oauth, %{"state" => state, "verifier" => verifier})
    |> redirect(external: Login.authorize_url(state, verifier, callback_url()))
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    case get_session(conn, :forgejo_oauth) do
      %{"state" => ^state, "verifier" => verifier} ->
        conn = delete_session(conn, :forgejo_oauth)
        opts = [teams: Accounts.teams_configured?()]

        with {:ok, identity, profile, token} <-
               Login.complete(code, verifier, callback_url(), opts),
             {:allowed, true} <-
               {:allowed, profile.active? and Accounts.allowed?(profile.orgs, profile.teams)},
             {:ok, user} <- Accounts.upsert_from_forgejo(identity),
             {:ok, _} <- Connections.store_forgejo(user, token, profile) do
          Audit.log_web(Scope.for_user(user, ip: ip(conn)), "login", %{})
          UserAuth.log_in(conn, user)
        else
          {:allowed, false} ->
            Logger.info("Forgejo sign-in refused: not in an allowed org or team")

            conn
            |> put_status(403)
            |> render_error(
              gettext(
                "Your Forgejo account is not in an organization or team allowed to use Switchboard."
              )
            )

          {:error, reason} ->
            Logger.warning("Forgejo login failed: #{inspect(reason)}")

            conn
            |> put_status(502)
            |> render_error(gettext("Signing in with Forgejo failed. Try again."))
        end

      _ ->
        conn
        |> put_status(400)
        |> render_error(
          gettext("The sign-in request expired or did not come from this browser. Try again.")
        )
    end
  end

  def callback(conn, %{"error" => _}) do
    conn |> put_status(400) |> render_error(gettext("Forgejo sign-in was cancelled."))
  end

  def callback(conn, _params),
    do: conn |> put_status(400) |> render_error(gettext("Forgejo did not return a code."))

  def logout(conn, _params) do
    if scope = conn.assigns[:current_scope], do: Audit.log_web(scope, "logout", %{})
    UserAuth.log_out(conn)
  end

  defp render_error(conn, message) do
    conn
    |> put_view(SwitchboardWeb.OAuthHTML)
    |> render(:error,
      message: message,
      hint: gettext("Go back to Switchboard and sign in again."),
      page_title: gettext("Sign-in error")
    )
  end

  defp ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
  defp callback_url, do: Switchboard.OAuth.issuer() <> ~p"/auth/forgejo/callback"
  defp random, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
