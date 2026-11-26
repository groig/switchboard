defmodule Switchboard.OAuth.Grant do
  @moduledoc """
  One client connection for one person. Refresh tokens rotate inside a grant; revoking the grant
  revokes every token in it (that is also what refresh-token reuse does).
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "oauth_grants" do
    belongs_to :user, Switchboard.Accounts.User
    field :client_id, :string
    field :client_name, :string
    field :resource, :string
    field :scope, :string
    field :revoked_at, :utc_datetime
    field :revoked_reason, :string
    field :last_used_at, :utc_datetime
    has_many :tokens, Switchboard.OAuth.Token

    timestamps(type: :utc_datetime)
  end
end
