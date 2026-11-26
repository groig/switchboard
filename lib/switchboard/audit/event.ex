defmodule Switchboard.Audit.Event do
  @moduledoc "One audit row. Append-only (a database trigger refuses updates and deletes)."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "audit_events" do
    field :at, :utc_datetime_usec
    field :user_id, :binary_id
    field :username, :string
    field :kind, :string
    field :action, :string
    field :client_id, :string
    field :client_name, :string
    field :args, :map, default: %{}
    field :outcome, :string
    field :error, :string
    field :duration_ms, :integer
    field :result_bytes, :integer
    field :upstreams, {:array, :string}, default: []
    field :ip, :string
  end
end
