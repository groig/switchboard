defmodule SwitchboardWeb.GitHubAuthController do
  @moduledoc """
  Connect GitHub (signed in): the OAuth App's authorize redirect and its callback. The `state`
  and the PKCE verifier live in the session; a callback whose `state` doesn't match is refused.
  The token is stored encrypted by `Switchboard.Connections.store_github/3` and never reaches the
  browser.
  """
  use SwitchboardWeb, :controller

  alias Switchboard.{Connections, GitHub}
  alias Switchboard.GitHub.Login

  require Logger

  @back "/connections#connection-github"

  def connect(conn, _params) do
    if GitHub.configured?() do
      state = random()
      verifier = random()

      conn
      |> put_session(:github_oauth, %{"state" => state, "verifier" => verifier})
      |> redirect(external: Login.authorize_url(state, verifier, callback_url()))
    else
      not_configured(conn)
    end
  end

  def callback(conn, params) do
    session = get_session(conn, :github_oauth)
    conn = delete_session(conn, :github_oauth)

    cond do
      not GitHub.configured?() ->
        not_configured(conn)

      not match?(%{"state" => s} when is_binary(s), session) or
          not Plug.Crypto.secure_compare(session["state"], to_string(params["state"])) ->
        back(
          conn,
          :error,
          gettext(
            "The GitHub connection request expired or did not come from this browser. Try again."
          )
        )

      params["error"] ->
        back(conn, :error, gettext("Connecting GitHub was cancelled."))

      not is_binary(params["code"]) ->
        back(conn, :error, gettext("GitHub did not return a code. Try again."))

      true ->
        finish(conn, params["code"], session["verifier"])
    end
  end

  defp finish(conn, code, verifier) do
    scope = conn.assigns.current_scope

    with {:ok, token, identity} <- Login.complete(code, verifier, callback_url()),
         {:ok, _connection} <- Connections.store_github(scope, token, identity) do
      back(
        conn,
        :info,
        gettext("GitHub connected as @%{login}.", login: identity["username"])
      )
    else
      {:error, reason} ->
        Logger.warning("GitHub connection failed: #{inspect(reason)}")
        back(conn, :error, gettext("Connecting GitHub failed. Try again."))
    end
  end

  defp not_configured(conn),
    do: back(conn, :error, gettext("GitHub is not set up on this Switchboard."))

  defp back(conn, kind, message), do: conn |> put_flash(kind, message) |> redirect(to: @back)

  defp callback_url, do: Switchboard.OAuth.issuer() <> ~p"/auth/github/callback"
  defp random, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
