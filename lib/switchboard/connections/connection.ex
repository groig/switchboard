defmodule Switchboard.Connections.Connection do
  @moduledoc """
  A person's credential for one upstream system. `secret` is encrypted at rest and redacted from
  `inspect/1`; only `Switchboard.Connections` reads it, and nothing ever renders or returns it.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "connections" do
    belongs_to :user, Switchboard.Accounts.User
    field :system, :string
    field :secret, Switchboard.Encrypted.Map, redact: true
    field :identity, :map, default: %{}
    field :identity_matches, :boolean
    field :status, :string, default: "untested"
    field :last_error, :string
    field :last_tested_at, :utc_datetime
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end
end
