defmodule Switchboard.PersonalTokens.PersonalToken do
  @moduledoc "A personal gateway token (`sb_...`). Only its SHA-256 is stored."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "personal_tokens" do
    belongs_to :user, Switchboard.Accounts.User
    field :name, :string
    field :token_hash, :binary, redact: true
    field :hint, :string
    field :expires_at, :utc_datetime
    field :last_used_at, :utc_datetime
    field :revoked_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end
end
