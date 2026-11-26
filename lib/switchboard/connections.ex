defmodule Switchboard.Connections do
  @moduledoc """
  Each person's upstream credentials (the "Connections" page).

  Secrets are encrypted at rest (`Switchboard.Vault`). They are read only here, handed only to
  upstream adapters, and never logged, rendered or put in a tool result. Linking a key tests it
  first and records who it belongs to, so the page can warn when it isn't the person's own
  (matched by email, case-insensitive; by username when the upstream reports no email).
  """
  import Ecto.Query

  alias Switchboard.Accounts.User
  alias Switchboard.Connections.Connection
  alias Switchboard.Forgejo.Login
  alias Switchboard.{Audit, Repo, Scope, Upstreams}

  require Logger

  # Refresh the Forgejo token when it has less than this left.
  @refresh_margin 120

  @doc "The person's connections, as a map of system => `%Connection{}`."
  def list(%Scope{user: user}) do
    from(c in Connection, where: c.user_id == ^user.id)
    |> Repo.all()
    |> Map.new(&{&1.system, &1})
  end

  def get(%User{} = user, system), do: Repo.get_by(Connection, user_id: user.id, system: system)

  @doc """
  Links (or replaces) a credential: validates the fields, tests it upstream, then stores it.

  A rejected credential is not stored. When the upstream can't be reached the credential is
  stored as untested, so an outage doesn't block linking.
  """
  def link(%Scope{user: user} = scope, system, params) when is_map(params) do
    with {:ok, mod} <- fetch_linkable(system),
         {:ok, secret} <- secret_from_params(mod, params) do
      case mod.whoami(secret) do
        {:ok, identity} ->
          store(user, system, secret, tested(user, identity))
          |> audited(scope, "connection.linked", system)

        {:error, :unauthorized} ->
          {:error, :rejected}

        {:error, :invalid_format} ->
          {:error, :invalid_format}

        {:error, reason} ->
          Logger.warning("#{system} key test failed: #{inspect(reason)}")

          store(user, system, secret, %{status: "untested", last_error: error_text(reason)})
          |> audited(scope, "connection.linked", system)
      end
    end
  end

  defp fetch_linkable("forgejo"), do: {:error, :not_linkable}

  defp fetch_linkable(system) do
    case Upstreams.fetch(system) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, :unknown_system}
    end
  end

  defp secret_from_params(mod, params) do
    values =
      for %{name: name} <- mod.fields(), into: %{} do
        {name, params |> Map.get(name, "") |> to_string() |> String.trim()}
      end

    if Enum.any?(values, fn {_k, v} -> v == "" or byte_size(v) > 512 end),
      do: {:error, :missing_fields},
      else: {:ok, values}
  end

  defp store(user, system, secret, attrs) do
    now = DateTime.utc_now(:second)

    connection =
      get(user, system) || %Connection{user_id: user.id, system: system}

    connection
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          secret: secret,
          identity: %{},
          identity_matches: nil,
          last_error: nil,
          last_tested_at: now
        },
        attrs
      )
    )
    |> Repo.insert_or_update()
  end

  defp tested(user, identity) do
    %{
      status: "ok",
      identity: identity,
      identity_matches: identity_matches(user, identity),
      last_error: nil
    }
  end

  @doc """
  Whether an upstream identity is the person's own: same email (case-insensitive), or the same
  username when the upstream reports no email. `nil` when there is nothing to compare.
  """
  def identity_matches(%User{} = user, identity) do
    email = identity["email"]
    username = identity["username"]

    cond do
      present?(email) and present?(user.email) -> eq?(email, user.email)
      present?(username) -> eq?(username, user.username)
      true -> nil
    end
  end

  defp present?(s), do: is_binary(s) and s != ""
  defp eq?(a, b), do: String.downcase(String.trim(a)) == String.downcase(String.trim(b))

  @doc "Tests a stored credential again and records the result."
  def test(%Scope{user: user} = scope, system) do
    with %Connection{} = conn <- get(user, system) || {:error, :not_connected},
         {:ok, mod} <- Upstreams.fetch(system) |> ok_or(:unknown_system),
         {:ok, secret} <- current_secret(user, conn) do
      now = DateTime.utc_now(:second)

      attrs =
        case mod.whoami(secret) do
          {:ok, identity} -> tested(user, identity)
          {:error, :unauthorized} -> %{status: "rejected", last_error: "rejected"}
          {:error, reason} -> %{status: "error", last_error: error_text(reason)}
        end

      # Re-read: the Forgejo token may have been refreshed (and the row updated) above.
      updated = get(user, system) |> Ecto.Changeset.change(Map.put(attrs, :last_tested_at, now))
      result = Repo.update(updated)
      Audit.log_web(scope, "connection.tested", %{system: system, status: attrs.status})
      result
    end
  end

  defp current_secret(user, %Connection{system: "forgejo"}) do
    with {:ok, token} <- forgejo_token(user), do: {:ok, %{"access_token" => token}}
  end

  defp current_secret(_user, %Connection{secret: secret}), do: {:ok, secret}

  defp ok_or({:ok, v}, _), do: {:ok, v}
  defp ok_or(:error, reason), do: {:error, reason}

  @doc "Removes a connection. Forgejo can't be removed (it comes from sign-in)."
  def unlink(%Scope{}, "forgejo"), do: {:error, :not_linkable}

  def unlink(%Scope{user: user} = scope, system) do
    {count, _} =
      from(c in Connection, where: c.user_id == ^user.id and c.system == ^system)
      |> Repo.delete_all()

    if count > 0, do: Audit.log_web(scope, "connection.unlinked", %{system: system})
    :ok
  end

  @doc """
  The decrypted secret for one of the person's connections, for upstream adapters only.
  Never for Forgejo: use `forgejo_token/1`.
  """
  def credential(%User{} = user, system) when system != "forgejo" do
    case get(user, system) do
      %Connection{status: status, secret: secret} when status != "rejected" -> {:ok, secret}
      %Connection{} -> {:error, :rejected}
      nil -> {:error, :not_connected}
    end
  end

  ## Forgejo

  @doc "Stores the Forgejo token from sign-in."
  def store_forgejo(%User{} = user, %{access_token: _} = token, profile) do
    store(user, "forgejo", forgejo_secret(token), %{
      status: "ok",
      identity: %{
        "username" => profile.identity.username,
        "email" => profile.identity.email,
        "name" => profile.identity.name
      },
      identity_matches: true,
      expires_at: token.expires_at
    })
  end

  defp forgejo_secret(token) do
    %{"access_token" => token.access_token, "refresh_token" => token.refresh_token}
  end

  @doc """
  A valid Forgejo access token for the person, refreshing it (under a row lock, so concurrent
  callers refresh once) when it is about to expire.
  """
  def forgejo_token(%User{} = user) do
    case get(user, "forgejo") do
      nil ->
        {:error, :not_connected}

      %Connection{secret: secret} = conn ->
        if fresh?(conn), do: {:ok, secret["access_token"]}, else: refresh_forgejo(user)
    end
  end

  defp fresh?(%Connection{expires_at: nil}), do: true

  defp fresh?(%Connection{expires_at: at}),
    do: DateTime.diff(at, DateTime.utc_now()) > @refresh_margin

  defp refresh_forgejo(user) do
    Repo.transact(fn ->
      conn =
        from(c in Connection,
          where: c.user_id == ^user.id and c.system == "forgejo",
          lock: "FOR UPDATE"
        )
        |> Repo.one()

      cond do
        is_nil(conn) ->
          {:error, :not_connected}

        # Someone else refreshed while we waited for the lock.
        fresh?(conn) ->
          {:ok, conn.secret["access_token"]}

        is_nil(conn.secret["refresh_token"]) ->
          {:error, :unauthorized}

        true ->
          case Login.refresh(conn.secret["refresh_token"]) do
            {:ok, token} ->
              conn
              |> Ecto.Changeset.change(
                secret: forgejo_secret(token),
                expires_at: token.expires_at,
                status: "ok",
                last_error: nil
              )
              |> Repo.update!()

              {:ok, token.access_token}

            {:error, :unauthorized} ->
              conn
              |> Ecto.Changeset.change(status: "rejected", last_error: "refresh rejected")
              |> Repo.update!()

              # Commit the status, then report.
              {:ok, {:refresh_rejected}}

            {:error, reason} ->
              {:error, reason}
          end
      end
    end)
    |> case do
      {:ok, {:refresh_rejected}} -> {:error, :unauthorized}
      other -> other
    end
  end

  ## Maintenance

  @doc "Re-encrypts every secret with the current vault key (after rotating `CLOAK_KEY`)."
  def reencrypt_all do
    Connection
    |> Repo.all()
    |> Enum.each(fn conn ->
      # Forcing the change makes Ecto write the field even though the plaintext is the same.
      conn
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.force_change(:secret, conn.secret)
      |> Repo.update!()
    end)
  end

  defp audited({:ok, conn} = result, scope, action, system) do
    Audit.log_web(scope, action, %{system: system, status: conn.status})
    result
  end

  defp audited(error, _scope, _action, _system), do: error

  defp error_text(:timeout), do: "timeout"
  defp error_text(:too_large), do: "response too large"
  defp error_text({:status, status}), do: "HTTP #{status}"
  defp error_text({:transport, _}), do: "unreachable"
  defp error_text(:unexpected_response), do: "unexpected response"
  defp error_text(_), do: "unavailable"
end
