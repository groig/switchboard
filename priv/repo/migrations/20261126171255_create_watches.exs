defmodule Switchboard.Repo.Migrations.CreateWatches do
  use Ecto.Migration

  def change do
    # "DM me when this finishes." One row per watch; see docs/ARCHITECTURE.md ("Watches").
    create table(:watches, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      # ci | task | release
      add :kind, :string, null: false
      # What it watches: %{"repo", "pr" | "branch" | "run"}, %{"id"}, %{"repo"}.
      add :target, :map, null: false
      # Lookup key: "owner/name" (lowercase) for ci, "PROJ-123" for task, the repo for release.
      add :subject, :string, null: false
      add :options, :map, null: false, default: %{}
      # active | fired | expired | cancelled
      add :status, :string, null: false, default: "active"
      add :expires_at, :utc_datetime, null: false
      # What the last poll saw (run status, Plane state, release name...), never message text.
      add :last_state, :map, null: false, default: %{}
      # Why it ended: notified, succeeded_quietly, timed_out, cancelled, access_lost...
      add :end_reason, :string
      add :ended_at, :utc_datetime
      # Set (conditionally, once) before the DM goes out: a notice is never sent twice.
      add :notified_at, :utc_datetime
      add :health_notified_at, :utc_datetime
      # Per notice ("result", "health"): "sending", then "sent" (or "unsure"). Claimed before the
      # DM, so a retried or rescued job never posts it again.
      add :deliveries, :map, null: false, default: %{}
      add :checks, :integer, null: false, default: 0
      add :last_checked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:watches, [:user_id, :status])
    create index(:watches, [:kind, :subject], where: "status = 'active'", name: :watches_active)

    alter table(:global_controls) do
      # Kill switch for every watch: no new watches, no polling, no notices while paused.
      add :watches_paused, :boolean, null: false, default: false
    end
  end
end
