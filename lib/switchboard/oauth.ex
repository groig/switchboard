defmodule Switchboard.OAuth do
  @moduledoc """
  Switchboard's OAuth 2.1 authorization server, for MCP clients.

  * Clients are identified by a Client ID Metadata Document URL (CIMD, preferred) or registered
    through Dynamic Client Registration (RFC 7591, fallback). All clients are public: PKCE (S256)
    is mandatory and there are no client secrets.
  * Every code and token is bound to one resource: `resource/0`, the canonical `/mcp` URL.
  * Access tokens are opaque, hashed at rest and live `@access_ttl` seconds. Refresh tokens rotate
    on every use; presenting a used refresh token revokes its whole grant (token family).
  """

  import Ecto.Query

  alias Switchboard.Accounts.User
  alias Switchboard.Audit
  alias Switchboard.OAuth.{CIMD, Client, Code, Grant, Token}
  alias Switchboard.{Repo, Scope}

  @access_ttl 3600
  @refresh_ttl 30 * 24 * 3600
  @code_ttl 60
  @cimd_cache_ttl 24 * 3600

  @access_prefix "sbat_"
  @refresh_prefix "sbrt_"

  ## Identity of this server

  @doc "The issuer identifier: the public base URL, without a trailing slash."
  def issuer, do: Application.fetch_env!(:switchboard, :public_url) |> String.trim_trailing("/")

  @doc "The canonical URI of the protected MCP resource."
  def resource, do: issuer() <> "/mcp"

  def access_ttl, do: @access_ttl

  ## Clients

  @doc """
  Looks up a client by `client_id`. A CIMD URL is fetched (SSRF-safe) and cached for a day.
  """
  def get_client(client_id) when is_binary(client_id) do
    if CIMD.cimd_client_id?(client_id),
      do: get_cimd_client(client_id),
      else: get_dcr_client(client_id)
  end

  def get_client(_), do: {:error, :invalid_client}

  defp get_dcr_client(client_id) do
    case Repo.get_by(Client, client_id: client_id, kind: "dcr") do
      nil -> {:error, :invalid_client}
      client -> {:ok, client}
    end
  end

  defp get_cimd_client(url) do
    cached = Repo.get_by(Client, client_id: url, kind: "cimd")

    if cached && DateTime.diff(DateTime.utc_now(), cached.fetched_at) < @cimd_cache_ttl do
      {:ok, cached}
    else
      case CIMD.fetch(url) do
        {:ok, attrs} ->
          attrs =
            Map.merge(attrs, %{
              client_id: url,
              kind: "cimd",
              fetched_at: DateTime.utc_now(:second)
            })

          (cached || %Client{})
          |> Client.changeset(attrs)
          |> Repo.insert_or_update()

        {:error, reason} ->
          {:error, {:invalid_client_metadata, reason}}
      end
    end
  end

  @doc """
  Dynamic Client Registration (RFC 7591). Only public clients using `none` auth. With an audit
  scope (the request's IP, no user), the registration or its rejection is recorded
  (`oauth.registered`, `oauth.register_failed`).
  """
  def register_client(params, audit \\ nil) when is_map(params) do
    result = do_register(params)

    if audit do
      base = %{
        client_name: params["client_name"],
        redirect_uris: params["redirect_uris"],
        token_endpoint_auth_method: params["token_endpoint_auth_method"],
        software_id: params["software_id"],
        software_version: params["software_version"]
      }

      case result do
        {:ok, client} ->
          Audit.log_web(
            %{audit | client_id: client.client_id, client_name: client.client_name},
            "oauth.registered",
            Map.put(base, :client_id, client.client_id)
          )

        {:error, error, description} ->
          Audit.log_web(
            %{audit | client_name: str(params["client_name"])},
            "oauth.register_failed",
            Map.put(base, :reason, to_string(error)),
            outcome: "error",
            error: description
          )
      end
    end

    result
  end

  defp str(s) when is_binary(s), do: String.slice(s, 0, 200)
  defp str(_), do: nil

  defp do_register(params) do
    redirect_uris = params["redirect_uris"]

    cond do
      not (is_list(redirect_uris) and redirect_uris != [] and
               Enum.all?(redirect_uris, &valid_redirect_uri?/1)) ->
        {:error, :invalid_redirect_uri, "redirect_uris must be https or loopback http URLs"}

      params["token_endpoint_auth_method"] not in [nil, "none"] ->
        {:error, :invalid_client_metadata,
         "only public clients (token_endpoint_auth_method=none) are supported"}

      true ->
        attrs = %{
          client_id: "sbc_" <> random_token(16),
          kind: "dcr",
          client_name:
            params["client_name"] |> then(&if(is_binary(&1), do: String.slice(&1, 0, 200))),
          client_uri: if(is_binary(params["client_uri"]), do: params["client_uri"]),
          redirect_uris: redirect_uris,
          metadata:
            Map.take(
              params,
              ~w(client_name client_uri redirect_uris grant_types response_types scope application_type software_id software_version)
            )
        }

        case %Client{} |> Client.changeset(attrs) |> Repo.insert() do
          {:ok, client} -> {:ok, client}
          {:error, _} -> {:error, :invalid_client_metadata, "invalid client metadata"}
        end
    end
  end

  defp valid_redirect_uri?(uri) when is_binary(uri) do
    case URI.new(uri) do
      {:ok, %URI{scheme: "https", host: h, fragment: nil}} when is_binary(h) and h != "" -> true
      {:ok, %URI{scheme: "http", host: h, fragment: nil}} -> loopback_host?(h)
      # Native apps may use private-use URI schemes (RFC 8252 §7.1), e.g. com.example.app:/cb
      {:ok, %URI{scheme: s, fragment: nil}} when is_binary(s) -> String.contains?(s, ".")
      _ -> false
    end
  end

  defp valid_redirect_uri?(_), do: false

  defp loopback_host?(h), do: h in ["127.0.0.1", "localhost", "[::1]", "::1"]

  @doc """
  Whether `requested` is one of the client's redirect URIs. Matching is exact, except that a
  loopback `http` URI may use any port (RFC 8252 §7.3), since native clients pick a free port.
  """
  def redirect_uri_allowed?(%Client{redirect_uris: registered}, requested)
      when is_binary(requested) do
    Enum.any?(registered, fn reg -> reg == requested or loopback_match?(reg, requested) end)
  end

  def redirect_uri_allowed?(_, _), do: false

  defp loopback_match?(registered, requested) do
    with {:ok, %URI{scheme: "http"} = a} <- URI.new(registered),
         {:ok, %URI{scheme: "http"} = b} <- URI.new(requested),
         true <- loopback_host?(a.host) and a.host == b.host do
      a.path == b.path and a.query == b.query and is_nil(b.fragment)
    else
      _ -> false
    end
  end

  ## Authorization requests

  @doc """
  Validates the parameters of `/oauth/authorize`.

  Returns `{:ok, request}`; `{:error, :no_redirect, message}` when the client or redirect URI
  cannot be trusted (the error is shown, never redirected); or
  `{:error, :redirect, redirect_uri, error, description, state}` for errors that go back to the
  client.
  """
  def validate_authorize_request(params, audit \\ nil) do
    result = do_validate_authorize(params)
    if audit, do: audit_authorize(audit, params, result)
    result
  end

  # A refused authorization request, for the admin audit view: which client, which redirect URI,
  # and why (never the code challenge or state).
  defp audit_authorize(_audit, _params, {:ok, _}), do: :ok

  defp audit_authorize(audit, params, error) do
    {reason, message} =
      case error do
        {:error, :no_redirect, message} -> {authorize_reason(message), message}
        {:error, :redirect, _uri, code, description, _state} -> {code, description}
      end

    client = Repo.get_by(Client, client_id: to_string(params["client_id"]))

    Audit.log_web(
      %{audit | client_id: str(params["client_id"]), client_name: client && client.client_name},
      "oauth.authorize_failed",
      %{
        reason: reason,
        client_id: str(params["client_id"]),
        client_kind: client && client.kind,
        redirect_uri: str(params["redirect_uri"]),
        registered_redirect_uris: client && client.redirect_uris,
        resource: str(params["resource"]),
        response_type: str(params["response_type"]),
        code_challenge_method: str(params["code_challenge_method"])
      },
      outcome: "error",
      error: message
    )
  end

  defp authorize_reason("Unknown client."), do: "unknown_client"

  defp authorize_reason("The redirect URI is not registered" <> _),
    do: "redirect_uri_not_registered"

  defp authorize_reason("The client's metadata document" <> _), do: "client_metadata_unusable"
  defp authorize_reason(_), do: "invalid_request"

  defp do_validate_authorize(params) do
    client_id = params["client_id"]
    redirect_uri = params["redirect_uri"]
    state = params["state"]

    with {:client, {:ok, client}} <- {:client, get_client(client_id)},
         {:redirect, true} <- {:redirect, redirect_uri_allowed?(client, redirect_uri)} do
      cond do
        params["response_type"] != "code" ->
          {:error, :redirect, redirect_uri, "unsupported_response_type",
           "response_type must be code", state}

        params["code_challenge_method"] != "S256" or
            not valid_challenge?(params["code_challenge"]) ->
          {:error, :redirect, redirect_uri, "invalid_request", "PKCE with S256 is required",
           state}

        not resource_ok?(params["resource"]) ->
          {:error, :redirect, redirect_uri, "invalid_target", "resource must be #{resource()}",
           state}

        true ->
          {:ok,
           %{
             client: client,
             client_id: client.client_id,
             redirect_uri: redirect_uri,
             code_challenge: params["code_challenge"],
             resource: resource(),
             scope: normalize_scope(params["scope"]),
             state: state
           }}
      end
    else
      {:client, {:error, {:invalid_client_metadata, reason}}} ->
        {:error, :no_redirect, "The client's metadata document could not be used (#{reason})."}

      {:client, {:error, _}} ->
        {:error, :no_redirect, "Unknown client."}

      {:redirect, false} ->
        {:error, :no_redirect, "The redirect URI is not registered for this client."}
    end
  end

  # 43..128 chars of base64url (RFC 7636 §4.2; an S256 challenge is exactly 43).
  defp valid_challenge?(c) when is_binary(c), do: c =~ ~r/\A[A-Za-z0-9\-._~]{43,128}\z/
  defp valid_challenge?(_), do: false

  # The resource parameter (RFC 8707) is required by MCP; we accept a trailing slash.
  defp resource_ok?(r) when is_binary(r), do: String.trim_trailing(r, "/") == resource()
  defp resource_ok?(_), do: false

  # Switchboard has a single scope today; whatever is asked, the grant is for the MCP resource.
  defp normalize_scope(_), do: "mcp"

  @doc "Issues a single-use authorization code for an approved request."
  def create_code(%User{} = user, request) do
    code = random_token(32)

    Repo.insert!(%Code{
      code_hash: hash(code),
      user_id: user.id,
      client_id: request.client_id,
      redirect_uri: request.redirect_uri,
      code_challenge: request.code_challenge,
      resource: request.resource,
      scope: request.scope,
      expires_at: DateTime.add(DateTime.utc_now(:second), @code_ttl)
    })

    code
  end

  ## Token endpoint

  @doc """
  Handles a token request. Returns `{:ok, token_response}` or `{:error, error, description}`
  (status 400 errors per RFC 6749 §5.2).
  """
  def token(params, audit \\ nil) do
    result = do_token(params)
    if audit, do: audit_token(audit, params, result)
    result
  end

  defp do_token(%{"grant_type" => "authorization_code"} = params), do: exchange_code(params)
  defp do_token(%{"grant_type" => "refresh_token"} = params), do: refresh(params)

  defp do_token(_),
    do:
      {:error, "unsupported_grant_type", "grant_type must be authorization_code or refresh_token"}

  # Every token request is audited (code exchange and refresh, success and failure) with the
  # person and client when Switchboard can tell, and the reason of a failure. Never the code,
  # the verifier or a token.
  defp audit_token(audit, params, result) do
    grant_type = str(params["grant_type"])
    {user, client_id, code_redirect} = token_subject(params)
    client_id = client_id || str(params["client_id"])
    client = client_id && Repo.get_by(Client, client_id: client_id)
    scope = %{audit | user: user, client_id: client_id, client_name: client && client.client_name}

    args = %{
      grant_type: grant_type,
      client_id: client_id,
      client_kind: client && client.kind,
      sent_client_id: params["client_id"] != nil,
      sent_resource: params["resource"] != nil
    }

    case result do
      {:ok, _} ->
        Audit.log_web(scope, "oauth.token_issued", args)

      {:error, error, description} ->
        reason =
          if error == "invalid_grant" and is_nil(client) and client_id,
            do: "unknown_client",
            else: token_reason(error, description)

        extra =
          if reason == "redirect_mismatch",
            do: %{redirect_uri: str(params["redirect_uri"]), code_redirect_uri: code_redirect},
            else: %{}

        Audit.log_web(
          scope,
          "oauth.token_failed",
          args |> Map.merge(extra) |> Map.put(:reason, reason),
          outcome: "error",
          error: "#{error}: #{description}"
        )
    end
  end

  # Who the code or refresh token belonged to (codes are kept after use, so a replay or a late
  # exchange still names the person).
  defp token_subject(%{"grant_type" => "authorization_code", "code" => code})
       when is_binary(code) do
    case Repo.one(from c in Code, where: c.code_hash == ^hash(code), preload: :user) do
      %Code{user: user, client_id: client_id, redirect_uri: uri} -> {user, client_id, uri}
      nil -> {nil, nil, nil}
    end
  end

  defp token_subject(%{"grant_type" => "refresh_token", "refresh_token" => token})
       when is_binary(token) do
    case Repo.one(
           from t in Token,
             join: g in assoc(t, :grant),
             join: u in assoc(g, :user),
             where: t.token_hash == ^hash(token) and t.kind == "refresh",
             select: {u, g.client_id}
         ) do
      {user, client_id} -> {user, client_id, nil}
      nil -> {nil, nil, nil}
    end
  end

  defp token_subject(_), do: {nil, nil, nil}

  @token_reasons %{
    "unknown code" => "unknown_code",
    "code already used" => "code_reused",
    "code expired" => "expired_code",
    "client_id mismatch" => "client_mismatch",
    "redirect_uri mismatch" => "redirect_mismatch",
    "PKCE verification failed" => "pkce_failed",
    "unknown refresh token" => "unknown_refresh_token",
    "grant revoked" => "grant_revoked",
    "refresh token expired" => "refresh_expired"
  }

  defp token_reason("invalid_target", _), do: "invalid_resource"
  defp token_reason("unsupported_grant_type", _), do: "unsupported_grant_type"

  defp token_reason(_error, description) do
    cond do
      reason = @token_reasons[description] -> reason
      description =~ "reuse" -> "refresh_reuse"
      description =~ "Forgejo" -> "membership_lost"
      true -> "invalid_grant"
    end
  end

  defp exchange_code(params) do
    now = DateTime.utc_now(:second)

    Repo.transact(fn ->
      code =
        params["code"]
        |> to_string()
        |> hash()
        |> then(&from(c in Code, where: c.code_hash == ^&1, lock: "FOR UPDATE"))
        |> Repo.one()

      cond do
        is_nil(code) ->
          {:error, {"invalid_grant", "unknown code"}}

        code.used_at != nil ->
          # Code replay: revoke whatever the first exchange produced (RFC 6749 §4.1.2).
          revoke_grants_for_code(code)
          {:ok, :replay}

        DateTime.compare(code.expires_at, now) != :gt ->
          {:error, {"invalid_grant", "code expired"}}

        code.client_id != params["client_id"] ->
          {:error, {"invalid_grant", "client_id mismatch"}}

        code.redirect_uri != params["redirect_uri"] ->
          {:error, {"invalid_grant", "redirect_uri mismatch"}}

        not pkce_ok?(params["code_verifier"], code.code_challenge) ->
          {:error, {"invalid_grant", "PKCE verification failed"}}

        not resource_ok?(params["resource"] || code.resource) ->
          {:error, {"invalid_target", "resource must be #{resource()}"}}

        true ->
          Repo.update!(Ecto.Changeset.change(code, used_at: now))
          client_name = client_name(code.client_id)

          grant =
            Repo.insert!(%Grant{
              user_id: code.user_id,
              client_id: code.client_id,
              client_name: client_name,
              resource: code.resource,
              scope: code.scope,
              last_used_at: now
            })

          {:ok, issue_tokens(grant)}
      end
    end)
    |> case do
      # Committed the revocation, then report the error.
      {:ok, :replay} -> {:error, "invalid_grant", "code already used"}
      other -> unwrap_token_result(other)
    end
  end

  defp revoke_grants_for_code(%Code{} = code) do
    # Grants created from this code: same user and client, created after the code was.
    from(g in Grant,
      where:
        g.user_id == ^code.user_id and g.client_id == ^code.client_id and
          g.inserted_at >= ^code.inserted_at and is_nil(g.revoked_at)
    )
    |> Repo.update_all(
      set: [revoked_at: DateTime.utc_now(:second), revoked_reason: "code_replay"]
    )
  end

  # Before rotating, ask Forgejo whether the person may still use Switchboard. Someone removed
  # from the allowed orgs (or deactivated) loses every client within the access-token lifetime.
  # A Forgejo outage fails open: the person keeps working, and the next refresh checks again.
  defp refresh(params) do
    with {:ok, user} <- refresh_token_user(params["refresh_token"]),
         {:error, :not_allowed} <- Switchboard.Accounts.recheck(user) do
      revoke_all_grants(user, "membership_lost")
      {:error, "invalid_grant", "your Forgejo account may no longer use Switchboard"}
    else
      _ -> rotate_refresh(params)
    end
  end

  defp refresh_token_user(token) when is_binary(token) do
    from(t in Token,
      join: g in assoc(t, :grant),
      join: u in assoc(g, :user),
      where: t.token_hash == ^hash(token) and t.kind == "refresh" and is_nil(g.revoked_at),
      select: u
    )
    |> Repo.one()
    |> case do
      nil -> :error
      user -> {:ok, user}
    end
  end

  defp refresh_token_user(_), do: :error

  defp rotate_refresh(params) do
    now = DateTime.utc_now(:second)

    Repo.transact(fn ->
      token =
        params["refresh_token"]
        |> to_string()
        |> hash()
        |> then(
          &from(t in Token,
            where: t.token_hash == ^&1 and t.kind == "refresh",
            lock: "FOR UPDATE",
            preload: :grant
          )
        )
        |> Repo.one()

      cond do
        is_nil(token) ->
          {:error, {"invalid_grant", "unknown refresh token"}}

        token.grant.revoked_at != nil ->
          {:error, {"invalid_grant", "grant revoked"}}

        token.used_at != nil ->
          # Reuse of a rotated refresh token: someone else holds the family. Revoke all of it.
          revoke_grant(token.grant, "refresh_reuse")
          {:ok, {:reuse, token.grant}}

        DateTime.compare(token.expires_at, now) != :gt ->
          {:error, {"invalid_grant", "refresh token expired"}}

        params["client_id"] != nil and params["client_id"] != token.grant.client_id ->
          {:error, {"invalid_grant", "client_id mismatch"}}

        params["resource"] != nil and not resource_ok?(params["resource"]) ->
          {:error, {"invalid_target", "resource must be #{resource()}"}}

        true ->
          Repo.update!(Ecto.Changeset.change(token, used_at: now))
          Repo.update!(Ecto.Changeset.change(token.grant, last_used_at: now))
          {:ok, issue_tokens(token.grant)}
      end
    end)
    |> case do
      # Committed the revocation, then report the error.
      {:ok, {:reuse, _grant}} ->
        {:error, "invalid_grant", "refresh token reuse detected; the connection was revoked"}

      other ->
        unwrap_token_result(other)
    end
  end

  defp unwrap_token_result({:ok, response}), do: {:ok, response}
  defp unwrap_token_result({:error, {error, description}}), do: {:error, error, description}

  defp pkce_ok?(verifier, challenge) when is_binary(verifier) do
    verifier =~ ~r/\A[A-Za-z0-9\-._~]{43,128}\z/ and
      Plug.Crypto.secure_compare(
        Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false),
        challenge
      )
  end

  defp pkce_ok?(_, _), do: false

  defp issue_tokens(%Grant{} = grant) do
    now = DateTime.utc_now(:second)
    access = @access_prefix <> random_token(32)
    refresh = @refresh_prefix <> random_token(32)

    Repo.insert_all(Token, [
      %{
        id: Ecto.UUID.generate(),
        grant_id: grant.id,
        kind: "access",
        token_hash: hash(access),
        expires_at: DateTime.add(now, @access_ttl),
        inserted_at: now
      },
      %{
        id: Ecto.UUID.generate(),
        grant_id: grant.id,
        kind: "refresh",
        token_hash: hash(refresh),
        expires_at: DateTime.add(now, @refresh_ttl),
        inserted_at: now
      }
    ])

    %{
      "access_token" => access,
      "token_type" => "Bearer",
      "expires_in" => @access_ttl,
      "refresh_token" => refresh,
      "scope" => grant.scope
    }
  end

  defp client_name(client_id) do
    case Repo.get_by(Client, client_id: client_id) do
      %Client{client_name: name} when is_binary(name) -> name
      _ -> nil
    end
  end

  ## Resource side

  @doc """
  Verifies a bearer access token for the MCP resource. Returns `{:ok, user, grant}` or
  `{:error, :invalid_token}`.
  """
  def verify_access_token(@access_prefix <> _ = token) do
    now = DateTime.utc_now(:second)

    query =
      from t in Token,
        join: g in assoc(t, :grant),
        join: u in assoc(g, :user),
        where: t.token_hash == ^hash(token) and t.kind == "access",
        where: t.expires_at > ^now and is_nil(g.revoked_at),
        select: {u, g}

    case Repo.one(query) do
      {user, %Grant{resource: res} = grant} ->
        if res == resource(), do: {:ok, user, grant}, else: {:error, :invalid_token}

      nil ->
        {:error, :invalid_token}
    end
  end

  def verify_access_token(_), do: {:error, :invalid_token}

  @doc "Revokes a grant and every token in it."
  def revoke_grant(%Grant{} = grant, reason) do
    grant
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second), revoked_reason: reason)
    |> Repo.update!()
  end

  @doc "The person's connected clients (active grants), most recently used first."
  def list_grants(%User{} = user) do
    from(g in Grant,
      where: g.user_id == ^user.id and is_nil(g.revoked_at),
      order_by: [desc_nulls_last: g.last_used_at, desc: g.inserted_at]
    )
    |> Repo.all()
  end

  @doc "Revokes one of the person's grants (from the web app)."
  def revoke_user_grant(%User{} = user, grant_id) do
    case Repo.get_by(Grant, id: grant_id, user_id: user.id) do
      %Grant{revoked_at: nil} = grant -> {:ok, revoke_grant(grant, "user_revoked")}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  The person's active grants grouped by client name (a client that registered itself on every
  login shows up once): `%{key:, name:, latest:, grants:}`, the most recently used first, and
  `latest` the most recently used grant of the group.
  """
  def grant_groups(%User{} = user) do
    user
    |> list_grants()
    |> Enum.group_by(&group_key/1)
    |> Enum.map(fn {key, grants} ->
      %{key: key, name: hd(grants).client_name, latest: hd(grants), grants: grants}
    end)
    |> Enum.sort_by(&sort_key(&1.latest), :desc)
  end

  defp group_key(%Grant{client_name: name}) when is_binary(name) and name != "",
    do: "name:" <> name

  defp group_key(%Grant{client_id: id}), do: "id:" <> id

  defp sort_key(%Grant{last_used_at: used, inserted_at: at}),
    do: DateTime.to_unix(used || at)

  @doc """
  Revokes a group's grants (`grant_groups/1`): all of them, or with `keep_latest: true` all but
  the most recently used (the stale duplicates). Audited. Returns how many were revoked.
  """
  def revoke_grant_group(%Scope{user: %User{} = user} = scope, key, opts \\ []) do
    case Enum.find(grant_groups(user), &(&1.key == key)) do
      nil ->
        {:error, :not_found}

      group ->
        targets = if opts[:keep_latest], do: tl(group.grants), else: group.grants
        ids = Enum.map(targets, & &1.id)

        {count, _} =
          from(g in Grant, where: g.id in ^ids and g.user_id == ^user.id and is_nil(g.revoked_at))
          |> Repo.update_all(
            set: [revoked_at: DateTime.utc_now(:second), revoked_reason: "user_revoked"]
          )

        action = if opts[:keep_latest], do: "client.removed_stale", else: "client.revoked"

        Audit.log_web(scope, action, %{
          client_name: group.name,
          client_ids: targets |> Enum.map(& &1.client_id) |> Enum.uniq(),
          count: count
        })

        {:ok, count}
    end
  end

  @doc "Revokes every active grant of a person. Returns how many."
  def revoke_all_grants(%User{} = user, reason) do
    {count, _} =
      from(g in Grant, where: g.user_id == ^user.id and is_nil(g.revoked_at))
      |> Repo.update_all(set: [revoked_at: DateTime.utc_now(:second), revoked_reason: reason])

    count
  end

  @doc "RFC 7009 revocation: revokes the grant a token belongs to. Unknown tokens are ignored."
  def revoke_token(token) when is_binary(token) do
    query = from t in Token, where: t.token_hash == ^hash(token), preload: :grant

    case Repo.one(query) do
      %Token{grant: grant} -> revoke_grant(grant, "client_revoked")
      nil -> :ok
    end

    :ok
  end

  def revoke_token(_), do: :ok

  ## Helpers

  defp random_token(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc false
  def hash(token), do: :crypto.hash(:sha256, token)
end
