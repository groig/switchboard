defmodule Switchboard.OAuth.Code do
  @moduledoc "A single-use authorization code (stored hashed, valid for one minute)."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "oauth_codes" do
    field :code_hash, :binary, redact: true
    belongs_to :user, Switchboard.Accounts.User
    field :client_id, :string
    field :redirect_uri, :string
    field :code_challenge, :string
    field :resource, :string
    field :scope, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
