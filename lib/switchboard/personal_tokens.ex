defmodule Switchboard.PersonalTokens do
  @moduledoc """
  Personal gateway tokens (`sb_...`) for MCP clients without OAuth. Sent as
  `Authorization: Bearer sb_...`. Shown once at creation, stored as a SHA-256 hash, optionally
  expiring, and revocable from the web app.
  """
  import Ecto.Query

  alias Switchboard.Accounts.User
  alias Switchboard.PersonalTokens.PersonalToken
  alias Switchboard.{Audit, OAuth, Repo, Scope}

  @prefix "sb_"
  @expiry_days [7, 30, 90, 365]
  @max_active 20

  def expiry_days, do: @expiry_days

  @doc "The person's tokens that are not revoked, newest first."
  def list(%Scope{user: user}) do
    from(t in PersonalToken,
      where: t.user_id == ^user.id and is_nil(t.revoked_at),
      order_by: [desc: t.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Creates a token. `expires_in_days` is one of `expiry_days/0` or nil (never). Returns
  `{:ok, plaintext, %PersonalToken{}}`; the plaintext is never retrievable again.
  """
  def create(%Scope{user: user} = scope, name, expires_in_days) do
    name = name |> to_string() |> String.trim() |> String.slice(0, 80)

    cond do
      name == "" ->
        {:error, :name_required}

      expires_in_days not in [nil | @expiry_days] ->
        {:error, :invalid_expiry}

      length(list(scope)) >= @max_active ->
        {:error, :too_many}

      true ->
        plaintext =
          @prefix <> (32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

        expires_at =
          expires_in_days &&
            DateTime.add(DateTime.utc_now(:second), expires_in_days * 86_400)

        token =
          Repo.insert!(%PersonalToken{
            user_id: user.id,
            name: name,
            token_hash: OAuth.hash(plaintext),
            hint: String.slice(plaintext, 0, 7),
            expires_at: expires_at
          })

        Audit.log_web(scope, "personal_token.created", %{
          name: name,
          expires_in_days: expires_in_days
        })

        {:ok, plaintext, token}
    end
  end

  @doc "Revokes one of the person's tokens."
  def revoke(%Scope{user: user} = scope, id) do
    {count, _} =
      from(t in PersonalToken,
        where: t.id == ^id and t.user_id == ^user.id and is_nil(t.revoked_at)
      )
      |> Repo.update_all(set: [revoked_at: DateTime.utc_now(:second)])

    if count == 1 do
      Audit.log_web(scope, "personal_token.revoked", %{id: id})
      :ok
    else
      {:error, :not_found}
    end
  end

  @doc "Revokes every token of a person. Returns how many."
  def revoke_all(%User{} = user) do
    {count, _} =
      from(t in PersonalToken, where: t.user_id == ^user.id and is_nil(t.revoked_at))
      |> Repo.update_all(set: [revoked_at: DateTime.utc_now(:second)])

    count
  end

  @doc "Checks a presented token: `{:ok, user, token}` or `{:error, :invalid_token}`."
  def verify(@prefix <> _ = plaintext) do
    now = DateTime.utc_now(:second)

    from(t in PersonalToken,
      join: u in assoc(t, :user),
      where: t.token_hash == ^OAuth.hash(plaintext) and is_nil(t.revoked_at),
      where: is_nil(t.expires_at) or t.expires_at > ^now,
      select: {t, u}
    )
    |> Repo.one()
    |> case do
      {token, user} ->
        touch(token, now)
        {:ok, user, token}

      nil ->
        {:error, :invalid_token}
    end
  end

  def verify(_), do: {:error, :invalid_token}

  # At most one write a minute per token.
  defp touch(%PersonalToken{last_used_at: last} = token, now) do
    if is_nil(last) or DateTime.diff(now, last) > 60 do
      from(t in PersonalToken, where: t.id == ^token.id)
      |> Repo.update_all(set: [last_used_at: now])
    end
  end
end
