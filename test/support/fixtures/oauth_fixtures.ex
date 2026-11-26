defmodule Switchboard.OAuthFixtures do
  @moduledoc "Users, clients and tokens for tests."
  alias Switchboard.{Accounts, Connections, OAuth}

  def public_resolver(_host), do: {:ok, [{93, 184, 215, 14}]}

  def user_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.upsert_from_forgejo(
        Map.merge(
          %{
            forgejo_id: n,
            username: "user#{n}",
            email: "user#{n}@example.com",
            name: "User #{n}"
          },
          Map.drop(attrs, [:forgejo])
        )
      )

    # Every signed-in person has the Forgejo token from sign-in.
    if Map.get(attrs, :forgejo, true) do
      {:ok, _} =
        Connections.store_forgejo(
          user,
          %{
            access_token: "forgejo-token-#{n}",
            refresh_token: "forgejo-refresh-#{n}",
            expires_at: DateTime.add(DateTime.utc_now(:second), 3600)
          },
          %{identity: %{username: user.username, email: user.email, name: user.name}}
        )
    end

    user
  end

  @doc """
  Stubs Forgejo's API for the test process: `/api/v1/user` answers as `user` (active unless
  `active: false`), `/api/v1/user/orgs` with `orgs` (default `["Acme"]`). A `:status`
  option makes every API call answer with that status instead.
  """
  def stub_forgejo(user, opts \\ []) do
    Req.Test.stub(Switchboard.Forgejo, fn conn ->
      case {opts[:status], conn.request_path} do
        {status, _} when is_integer(status) ->
          conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"message" => "nope"})

        {nil, "/api/v1/user"} ->
          Req.Test.json(conn, %{
            "id" => user.forgejo_id,
            "login" => user.username,
            "email" => user.email,
            "full_name" => user.name,
            "active" => Keyword.get(opts, :active, true)
          })

        {nil, "/api/v1/user/orgs"} ->
          Req.Test.json(
            conn,
            for(o <- Keyword.get(opts, :orgs, ["Acme"]), do: %{"username" => o})
          )

        {nil, "/api/v1/user/teams"} ->
          Req.Test.json(conn, [])
      end
    end)
  end

  def dcr_client_fixture(redirect_uris \\ ["http://127.0.0.1/callback"]) do
    {:ok, client} =
      OAuth.register_client(%{"client_name" => "Test client", "redirect_uris" => redirect_uris})

    client
  end

  def pkce_pair do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {verifier, Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)}
  end

  def authorize_params(client, challenge, overrides \\ %{}) do
    Map.merge(
      %{
        "response_type" => "code",
        "client_id" => client.client_id,
        "redirect_uri" => "http://127.0.0.1:53111/callback",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "resource" => OAuth.resource(),
        "state" => "xyz"
      },
      overrides
    )
  end

  @doc "Runs the whole code flow and returns `{user, client, token_response}`."
  def token_fixture(user \\ user_fixture()) do
    client = dcr_client_fixture()
    {verifier, challenge} = pkce_pair()
    {:ok, request} = OAuth.validate_authorize_request(authorize_params(client, challenge))
    code = OAuth.create_code(user, request)

    {:ok, tokens} =
      OAuth.token(%{
        "grant_type" => "authorization_code",
        "code" => code,
        "client_id" => client.client_id,
        "redirect_uri" => request.redirect_uri,
        "code_verifier" => verifier,
        "resource" => OAuth.resource()
      })

    {user, client, tokens}
  end
end
