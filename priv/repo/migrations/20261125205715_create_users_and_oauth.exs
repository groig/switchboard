defmodule Switchboard.Repo.Migrations.CreateUsersAndOauth do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", ""

    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :forgejo_id, :bigint, null: false
      add :username, :citext, null: false
      add :email, :citext
      add :name, :string
      add :admin, :boolean, null: false, default: false
      add :locale, :string, null: false, default: "es"
      add :time_zone, :string, null: false, default: "Europe/Madrid"
      add :last_login_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:forgejo_id])
    create unique_index(:users, [:username])

    # Clients registered through DCR, and CIMD clients we have seen (cached metadata).
    create table(:oauth_clients, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :client_id, :text, null: false
      add :kind, :string, null: false
      add :client_name, :string
      add :client_uri, :text
      add :redirect_uris, {:array, :text}, null: false, default: []
      add :metadata, :map, null: false, default: %{}
      add :fetched_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:oauth_clients, [:client_id])

    create table(:oauth_codes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :code_hash, :binary, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :client_id, :text, null: false
      add :redirect_uri, :text, null: false
      add :code_challenge, :string, null: false
      add :resource, :text, null: false
      add :scope, :string
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:oauth_codes, [:code_hash])

    # A grant is one client connection for one person: the family that refresh tokens rotate in.
    create table(:oauth_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :client_id, :text, null: false
      add :client_name, :string
      add :resource, :text, null: false
      add :scope, :string
      add :revoked_at, :utc_datetime
      add :revoked_reason, :string
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:oauth_grants, [:user_id])

    create table(:oauth_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :grant_id, references(:oauth_grants, type: :binary_id, on_delete: :delete_all),
        null: false

      add :kind, :string, null: false
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:oauth_tokens, [:token_hash])
    create index(:oauth_tokens, [:grant_id])
  end
end
