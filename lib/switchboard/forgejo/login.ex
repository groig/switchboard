defmodule Switchboard.Forgejo.Login do
  @moduledoc """
  Upstream OAuth2 login against Forgejo (authorization code + PKCE, confidential client).

  Forgejo 16 does not enforce scopes on OAuth2 tokens: whatever we ask for, the token can do
  anything the person can (see `docs/SECURITY.md`). We still request the narrow scopes we need,
  so the consent screen is honest and we are ready if Forgejo starts enforcing them. The token
  is stored encrypted (`Switchboard.Connections`) and only used by our own Forgejo adapter.
  """

  @scopes "read:user read:organization read:repository read:issue"

  def scopes, do: @scopes

  def authorize_url(state, verifier, redirect_uri) do
    query =
      URI.encode_query(%{
        "client_id" => config(:client_id),
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "scope" => @scopes,
        "state" => state,
        "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false),
        "code_challenge_method" => "S256"
      })

    base_url() <> "/login/oauth/authorize?" <> query
  end

  @type token :: %{
          access_token: String.t(),
          refresh_token: String.t() | nil,
          expires_at: DateTime.t() | nil
        }

  @doc """
  Exchanges the code, then returns the person's identity, their profile (active flag, orgs and,
  when `teams: true`, teams) and the token.
  """
  def complete(code, verifier, redirect_uri, opts \\ []) do
    form = %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => redirect_uri,
      "code_verifier" => verifier
    }

    with {:ok, token} <- token_request(form),
         {:ok, profile} <- fetch_profile(token.access_token, opts) do
      {:ok, profile.identity, profile, token}
    end
  end

  @doc "Trades a refresh token for a new token (Forgejo rotates the refresh token)."
  def refresh(refresh_token) when is_binary(refresh_token) do
    token_request(%{"grant_type" => "refresh_token", "refresh_token" => refresh_token})
  end

  defp token_request(form) do
    form =
      Map.merge(form, %{
        "client_id" => config(:client_id),
        "client_secret" => config(:client_secret)
      })

    case Req.post(req(), url: "/login/oauth/access_token", form: form) do
      {:ok, %{status: 200, body: %{"access_token" => access} = body}} ->
        {:ok,
         %{
           access_token: access,
           refresh_token: body["refresh_token"],
           expires_at: expires_at(body["expires_in"])
         }}

      {:ok, %{status: status}} when status in [400, 401] ->
        {:error, :unauthorized}

      {:ok, %{status: status}} ->
        {:error, {:token_request, status}}

      {:error, e} ->
        {:error, {:token_request, Exception.message(e)}}
    end
  end

  defp expires_at(seconds) when is_integer(seconds),
    do: DateTime.add(DateTime.utc_now(:second), seconds)

  defp expires_at(_), do: nil

  @doc """
  The person behind a token: `%{identity:, active?:, orgs:, teams:}`. Teams are only fetched
  with `teams: true` (they need an extra request).
  """
  def fetch_profile(access_token, opts \\ []) do
    with {:ok, user} <- api_get(access_token, "/api/v1/user"),
         {:ok, orgs} <- api_get(access_token, "/api/v1/user/orgs?limit=50"),
         {:ok, teams} <- maybe_teams(access_token, opts[:teams]) do
      {:ok,
       %{
         identity: %{
           forgejo_id: user["id"],
           username: user["login"],
           email: user["email"],
           name: blank_to_nil(user["full_name"])
         },
         active?: user["active"] != false and user["prohibit_login"] != true,
         orgs: Enum.map(orgs, & &1["username"]),
         teams: teams
       }}
    end
  end

  defp maybe_teams(token, true) do
    with {:ok, teams} <- api_get(token, "/api/v1/user/teams?limit=50") do
      {:ok, for(t <- teams, org = t["organization"]["username"], do: "#{org}/#{t["name"]}")}
    end
  end

  defp maybe_teams(_token, _), do: {:ok, []}

  defp api_get(token, path) do
    case Req.get(req(), url: path, auth: {:bearer, token}) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 401}} -> {:error, :unauthorized}
      {:ok, %{status: status}} -> {:error, {:api, path, status}}
      {:error, e} -> {:error, {:api, path, Exception.message(e)}}
    end
  end

  defp req do
    Req.new(
      [
        base_url: base_url(),
        receive_timeout: 10_000,
        connect_options: [timeout: 5_000],
        retry: false,
        headers: [accept: "application/json"]
      ] ++ (config(:req_options) || [])
    )
  end

  @doc "The Forgejo base URL, without a trailing slash."
  def base_url, do: config(:url) |> String.trim_trailing("/")

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s

  defp config(key), do: Application.get_env(:switchboard, Switchboard.Forgejo, [])[key]
end
