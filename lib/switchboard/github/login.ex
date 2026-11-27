defmodule Switchboard.GitHub.Login do
  @moduledoc """
  Linking a person's GitHub account through Switchboard's **OAuth App** (authorization code,
  `state` checked by the controller, PKCE S256).

  Scope: `repo`, the minimum that reads private repositories' pull requests, checks and Actions
  logs. Classic OAuth Apps have no read-only variant of it, so the token could write; the guarantee
  is that Switchboard never does: tools read through `Switchboard.GitHub`, which only sends GET.
  The two non-GET requests in this module talk to the OAuth endpoints only: the code exchange and
  revoking the grant when the person disconnects.

  Requests go through `Switchboard.Upstreams.request/3` (timeouts, no redirects, body cap).
  """

  alias Switchboard.{GitHub, Upstreams}

  @scopes "repo"

  def scopes, do: @scopes

  def authorize_url(state, verifier, redirect_uri) do
    query =
      URI.encode_query(%{
        "client_id" => GitHub.client_id(),
        "redirect_uri" => redirect_uri,
        "scope" => @scopes,
        "state" => state,
        "allow_signup" => "false",
        "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false),
        "code_challenge_method" => "S256"
      })

    GitHub.web_url() <> "/login/oauth/authorize?" <> query
  end

  @doc """
  Exchanges the code for a token and reads who it belongs to:
  `{:ok, token, %{"username", "email", "name"}}`, or `{:error, reason}`.
  """
  def complete(code, verifier, redirect_uri) do
    with {:ok, token} <- exchange(code, verifier, redirect_uri),
         {:ok, identity} <- identity(token) do
      {:ok, token, identity}
    end
  end

  defp exchange(code, verifier, redirect_uri) do
    Upstreams.request(:github,
      method: :post,
      url: GitHub.web_url() <> "/login/oauth/access_token",
      form: %{
        "client_id" => GitHub.client_id(),
        "client_secret" => secret(),
        "code" => code,
        "redirect_uri" => redirect_uri,
        "code_verifier" => verifier
      }
    )
    |> case do
      # GitHub answers 200 with an `error` field for a bad or expired code.
      {:ok, %Req.Response{status: 200, body: %{"access_token" => token}}} when is_binary(token) ->
        {:ok, token}

      {:ok, %Req.Response{status: 200, body: %{"error" => error}}} ->
        {:error, {:oauth, error}}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Who a token belongs to (`GET /user`), as a connection identity."
  def identity(token) do
    Upstreams.request(:github,
      url: "/user",
      auth: {:bearer, token},
      headers: [{"x-github-api-version", "2022-11-28"}]
    )
    |> Upstreams.classify()
    |> case do
      {:ok, %Req.Response{body: %{"login" => login} = user}} ->
        {:ok, %{"username" => login, "email" => user["email"], "name" => user["name"]}}

      {:ok, _} ->
        {:error, :unexpected_response}

      error ->
        error
    end
  end

  @doc """
  Revokes Switchboard's grant for the token's owner (`DELETE /applications/{client_id}/grant`,
  authenticated as the app): every token of this app for that person stops working, and the app
  disappears from their authorized apps. A token GitHub no longer knows counts as revoked.
  """
  def revoke(token) do
    Upstreams.request(:github,
      method: :delete,
      url: "/applications/#{GitHub.client_id()}/grant",
      auth: {:basic, "#{GitHub.client_id()}:#{secret()}"},
      headers: [{"x-github-api-version", "2022-11-28"}],
      json: %{"access_token" => token}
    )
    |> case do
      {:ok, %Req.Response{status: status}} when status in [204, 404, 422] -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp secret, do: Application.get_env(:switchboard, GitHub, [])[:client_secret]
end
