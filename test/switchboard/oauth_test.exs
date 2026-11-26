defmodule Switchboard.OAuthTest do
  use Switchboard.DataCase, async: true

  import Switchboard.OAuthFixtures
  alias Switchboard.OAuth

  describe "redirect URIs" do
    test "match exactly, except that loopback http may use any port" do
      client = %OAuth.Client{
        redirect_uris: ["http://localhost/callback", "https://app.example.com/cb"]
      }

      assert OAuth.redirect_uri_allowed?(client, "http://localhost:64156/callback")
      assert OAuth.redirect_uri_allowed?(client, "http://localhost/callback")
      assert OAuth.redirect_uri_allowed?(client, "https://app.example.com/cb")
      refute OAuth.redirect_uri_allowed?(client, "https://app.example.com:8443/cb")
      refute OAuth.redirect_uri_allowed?(client, "https://app.example.com/cb/extra")
      refute OAuth.redirect_uri_allowed?(client, "http://localhost:1234/other")
      refute OAuth.redirect_uri_allowed?(client, "http://127.0.0.1:1234/callback")
      refute OAuth.redirect_uri_allowed?(client, "http://evil.example/callback")
    end

    test "DCR rejects non-https, non-loopback redirect URIs" do
      assert {:error, :invalid_redirect_uri, _} =
               OAuth.register_client(%{"redirect_uris" => ["http://evil.example/cb"]})

      assert {:error, :invalid_redirect_uri, _} = OAuth.register_client(%{"redirect_uris" => []})

      assert {:error, :invalid_client_metadata, _} =
               OAuth.register_client(%{
                 "redirect_uris" => ["https://a.example/cb"],
                 "token_endpoint_auth_method" => "client_secret_basic"
               })
    end
  end

  describe "authorize requests" do
    setup do
      %{client: dcr_client_fixture(), pkce: pkce_pair()}
    end

    test "require PKCE S256", %{client: client, pkce: {_, challenge}} do
      assert {:error, :redirect, _, "invalid_request", _, "xyz"} =
               OAuth.validate_authorize_request(
                 authorize_params(client, challenge, %{"code_challenge_method" => "plain"})
               )

      assert {:error, :redirect, _, "invalid_request", _, _} =
               OAuth.validate_authorize_request(
                 Map.delete(authorize_params(client, challenge), "code_challenge")
               )
    end

    test "require the resource to be this server", %{client: client, pkce: {_, challenge}} do
      assert {:error, :redirect, _, "invalid_target", _, _} =
               OAuth.validate_authorize_request(
                 authorize_params(client, challenge, %{"resource" => "https://other.example/mcp"})
               )

      assert {:error, :redirect, _, "invalid_target", _, _} =
               OAuth.validate_authorize_request(
                 Map.delete(authorize_params(client, challenge), "resource")
               )
    end

    test "never redirect to an unregistered URI or for an unknown client", %{
      client: client,
      pkce: {_, challenge}
    } do
      assert {:error, :no_redirect, _} =
               OAuth.validate_authorize_request(
                 authorize_params(client, challenge, %{
                   "redirect_uri" => "https://evil.example/cb"
                 })
               )

      assert {:error, :no_redirect, _} =
               OAuth.validate_authorize_request(
                 authorize_params(client, challenge, %{"client_id" => "sbc_unknown"})
               )
    end
  end

  describe "token endpoint" do
    test "a code works once, with the right verifier, and replay revokes the grant" do
      user = user_fixture()
      client = dcr_client_fixture()
      {verifier, challenge} = pkce_pair()
      {:ok, request} = OAuth.validate_authorize_request(authorize_params(client, challenge))
      code = OAuth.create_code(user, request)

      params = %{
        "grant_type" => "authorization_code",
        "code" => code,
        "client_id" => client.client_id,
        "redirect_uri" => request.redirect_uri,
        "resource" => OAuth.resource()
      }

      assert {:error, "invalid_grant", _} =
               OAuth.token(Map.put(params, "code_verifier", elem(pkce_pair(), 0)))

      assert {:ok, %{"access_token" => access}} =
               OAuth.token(Map.put(params, "code_verifier", verifier))

      assert {:ok, _, _} = OAuth.verify_access_token(access)

      assert {:error, "invalid_grant", _} =
               OAuth.token(Map.put(params, "code_verifier", verifier))

      assert {:error, :invalid_token} = OAuth.verify_access_token(access)
    end

    test "refresh tokens rotate, and reuse revokes the whole family" do
      {user, client, %{"refresh_token" => r1, "access_token" => a1}} = token_fixture()
      stub_forgejo(user)

      refresh =
        &OAuth.token(%{
          "grant_type" => "refresh_token",
          "refresh_token" => &1,
          "client_id" => client.client_id
        })

      assert {:ok, %{"refresh_token" => r2, "access_token" => a2}} = refresh.(r1)
      assert r2 != r1
      assert {:error, "invalid_grant", _} = refresh.(r1)

      for token <- [a1, a2],
          do: assert({:error, :invalid_token} = OAuth.verify_access_token(token))

      assert {:error, "invalid_grant", _} = refresh.(r2)
    end

    test "a refresh re-checks Forgejo: leaving the allowed orgs revokes every client" do
      {user, client, %{"refresh_token" => r1, "access_token" => a1}} = token_fixture()
      {^user, _client2, %{"access_token" => other}} = token_fixture(user)
      stub_forgejo(user, orgs: ["SomewhereElse"])

      assert {:error, "invalid_grant", _} =
               OAuth.token(%{
                 "grant_type" => "refresh_token",
                 "refresh_token" => r1,
                 "client_id" => client.client_id
               })

      assert {:error, :invalid_token} = OAuth.verify_access_token(a1)
      assert {:error, :invalid_token} = OAuth.verify_access_token(other)
    end

    test "a deactivated or revoked Forgejo account loses access; an outage does not" do
      for {opts, outcome} <- [
            {[active: false], :revoked},
            {[status: 401], :revoked},
            {[status: 503], :kept}
          ] do
        {user, client, %{"refresh_token" => r1}} = token_fixture()
        stub_forgejo(user, opts)

        result =
          OAuth.token(%{
            "grant_type" => "refresh_token",
            "refresh_token" => r1,
            "client_id" => client.client_id
          })

        case outcome do
          :revoked -> assert {:error, "invalid_grant", _} = result
          :kept -> assert {:ok, %{"access_token" => _}} = result
        end
      end
    end

    test "access tokens are stored hashed" do
      {_user, _client, %{"access_token" => access}} = token_fixture()
      refute Repo.exists?(from t in OAuth.Token, where: t.token_hash == ^access)
      assert Repo.exists?(from t in OAuth.Token, where: t.token_hash == ^OAuth.hash(access))
    end
  end
end
