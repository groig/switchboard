defmodule Switchboard.Repo.Migrations.Foundation do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :theme, :string, null: false, default: "system"
      # Bumped to sign the person out of every browser (admin "revoke all").
      add :session_version, :integer, null: false, default: 1
    end

    # One row per person and upstream system. `secret` is encrypted (cloak_ecto); `identity` is
    # who the credential belongs to, as the upstream reported it on the last test.
    create table(:connections, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :system, :string, null: false
      add :secret, :binary, null: false
      add :identity, :map, null: false, default: %{}
      add :identity_matches, :boolean
      add :status, :string, null: false, default: "untested"
      add :last_error, :string
      add :last_tested_at, :utc_datetime
      add :expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:connections, [:user_id, :system])

    create table(:personal_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :token_hash, :binary, null: false
      # The first characters, to recognise a token in a list ("sb_k3Fq…").
      add :hint, :string, null: false
      add :expires_at, :utc_datetime
      add :last_used_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:personal_tokens, [:token_hash])
    create index(:personal_tokens, [:user_id])

    # Append-only. No foreign key on purpose: the trail outlives the person's account.
    create table(:audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :at, :utc_datetime_usec, null: false
      add :user_id, :binary_id
      add :username, :string
      add :kind, :string, null: false
      add :action, :string, null: false
      add :client_id, :text
      add :client_name, :string
      add :args, :map, null: false, default: %{}
      add :outcome, :string, null: false
      add :error, :text
      add :duration_ms, :integer
      add :result_bytes, :integer
      add :upstreams, {:array, :string}, null: false, default: []
      add :ip, :string
    end

    create index(:audit_events, [:at])
    create index(:audit_events, [:user_id, :at])
    create index(:audit_events, [:action, :at])

    execute(
      """
      CREATE FUNCTION audit_events_append_only() RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'DELETE' AND current_setting('switchboard.audit_prune', true) = 'on' THEN
          RETURN OLD;
        END IF;
        RAISE EXCEPTION 'audit_events is append-only';
      END
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION audit_events_append_only()"
    )

    execute(
      """
      CREATE TRIGGER audit_events_append_only
      BEFORE UPDATE OR DELETE ON audit_events
      FOR EACH ROW EXECUTE FUNCTION audit_events_append_only()
      """,
      "DROP TRIGGER audit_events_append_only ON audit_events"
    )

    # Live controls. A single row (id = 1) for the global switches.
    create table(:global_controls, primary_key: false) do
      add :id, :integer, primary_key: true
      add :read_only, :boolean, null: false, default: false
      add :maintenance_message, :string

      timestamps(type: :utc_datetime)
    end

    execute(
      "INSERT INTO global_controls (id, read_only, inserted_at, updated_at) VALUES (1, false, now(), now())",
      ""
    )

    create table(:tool_controls, primary_key: false) do
      add :tool, :string, primary_key: true
      add :enabled, :boolean, null: false, default: true
      # Calls per person per minute; NULL means the tool's default.
      add :rate_limit, :integer

      timestamps(type: :utc_datetime)
    end
  end
end
