defmodule Switchboard.Controls.Global do
  @moduledoc "The single row (id 1) of global switches."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}
  schema "global_controls" do
    field :read_only, :boolean, default: false
    field :maintenance_message, :string
    timestamps(type: :utc_datetime)
  end

  def changeset(global, attrs) do
    global
    |> cast(attrs, [:read_only, :maintenance_message])
    |> update_change(:maintenance_message, &(&1 && String.trim(&1)))
    |> validate_length(:maintenance_message, max: 200)
  end
end
