defmodule Switchboard.OAuth.Token do
  @moduledoc "An access or refresh token. Only its SHA-256 hash is stored."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "oauth_tokens" do
    belongs_to :grant, Switchboard.OAuth.Grant
    field :kind, :string
    field :token_hash, :binary, redact: true
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
