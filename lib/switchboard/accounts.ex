defmodule Switchboard.Accounts do
  @moduledoc """
  People, who may sign in, and their profile.

  Membership is checked against Forgejo at sign-in and again every time an MCP client refreshes
  its token (`recheck/1`), so someone removed from the allowed orgs loses access within an hour
  without anyone revoking anything by hand.
  """
  import Ecto.Query

  alias Switchboard.Accounts.User
  alias Switchboard.{Audit, Connections, OAuth, PersonalTokens, Repo, Scope}
  alias Switchboard.Forgejo.Login

  require Logger

  def get_user!(id), do: Repo.get!(User, id)
  def get_user(id), do: Repo.get(User, id)

  @doc "Everyone, most recently seen first (admin)."
  def list_users do
    Repo.all(from u in User, order_by: [desc_nulls_last: u.last_login_at, asc: u.username])
  end

  @doc """
  Creates or updates the user from the Forgejo identity seen at login.

  `identity` has `:forgejo_id`, `:username`, `:email` and `:name`. Admin status is derived from
  the configured admin usernames on every login, so removing someone from the list takes effect
  the next time they sign in.
  """
  def upsert_from_forgejo(identity) do
    attrs =
      identity
      |> Map.put(:admin, admin_username?(identity.username))
      |> Map.put(:last_login_at, DateTime.utc_now(:second))

    (Repo.get_by(User, forgejo_id: identity.forgejo_id) || %User{})
    |> User.login_changeset(attrs)
    |> Repo.insert_or_update()
  end

  defp admin_username?(username) do
    down = String.downcase(username)
    Enum.any?(config(:admin_usernames, []), &(String.downcase(&1) == down))
  end

  @doc """
  Whether a person who belongs to `orgs` (Forgejo org names) and `teams` (`"Org/team"`) may sign
  in: a member of any allowed org, or of any allowed team.
  """
  def allowed?(orgs, teams \\ []) do
    allowed_orgs = config(:allowed_forgejo_orgs, []) |> Enum.map(&String.downcase/1)
    allowed_teams = config(:allowed_forgejo_teams, []) |> Enum.map(&String.downcase/1)

    Enum.any?(orgs, &(String.downcase(&1) in allowed_orgs)) or
      Enum.any?(teams, &(String.downcase(&1) in allowed_teams))
  end

  @doc "Whether team membership needs checking at all (only when teams are configured)."
  def teams_configured?, do: config(:allowed_forgejo_teams, []) != []

  @doc """
  Checks with Forgejo, using the person's stored token, that they are still active and allowed.

  Returns `:ok`, `{:error, :not_allowed}` (revoked token, deactivated account or left the orgs)
  or `{:error, :unavailable}` when Forgejo can't be reached. Callers fail open on `:unavailable`
  so a Forgejo outage doesn't sign everyone out; access tokens still expire within the hour.
  """
  def recheck(%User{} = user) do
    with {:ok, token} <- Connections.forgejo_token(user),
         {:ok, profile} <- Login.fetch_profile(token, teams: teams_configured?()) do
      if profile.active? and allowed?(profile.orgs, profile.teams),
        do: :ok,
        else: {:error, :not_allowed}
    else
      {:error, :unauthorized} -> {:error, :not_allowed}
      {:error, :not_connected} -> {:error, :not_allowed}
      {:error, _} -> {:error, :unavailable}
    end
  end

  ## Profile

  def change_profile(%User{} = user, attrs \\ %{}), do: User.profile_changeset(user, attrs)

  def update_profile(%Scope{user: user} = scope, attrs) do
    with {:ok, updated} <- user |> User.profile_changeset(attrs) |> Repo.update() do
      Audit.log_web(scope, "profile.updated", %{
        locale: updated.locale,
        time_zone: updated.time_zone
      })

      {:ok, updated}
    end
  end

  def update_theme(%Scope{user: user}, theme) do
    user |> User.theme_changeset(theme) |> Repo.update()
  end

  ## Revocation

  @doc """
  Revokes everything a person has: OAuth client grants, personal tokens and browser sessions
  (admin). Upstream connections stay, so they don't have to re-link keys if access comes back.
  """
  def revoke_all(%Scope{user: %User{admin: true}} = admin, %User{} = user) do
    {:ok, _} =
      Repo.transact(fn ->
        grants = OAuth.revoke_all_grants(user, "admin_revoke_all")
        tokens = PersonalTokens.revoke_all(user)

        from(u in User, where: u.id == ^user.id)
        |> Repo.update_all(inc: [session_version: 1])

        {:ok, {grants, tokens}}
      end)
      |> tap(fn {:ok, {grants, tokens}} ->
        Audit.log_web(admin, "admin.revoke_all", %{
          username: user.username,
          grants: grants,
          personal_tokens: tokens
        })
      end)

    :ok
  end

  defp config(key, default),
    do: Application.get_env(:switchboard, __MODULE__, []) |> Keyword.get(key, default)
end
