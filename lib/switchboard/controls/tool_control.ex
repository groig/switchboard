defmodule Switchboard.Controls.ToolControl do
  @moduledoc "A per-tool override: kill switch and rate limit (calls per person per minute)."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:tool, :string, autogenerate: false}
  schema "tool_controls" do
    field :enabled, :boolean, default: true
    field :rate_limit, :integer
    timestamps(type: :utc_datetime)
  end

  def changeset(control, attrs) do
    control
    |> cast(attrs, [:enabled, :rate_limit])
    |> validate_number(:rate_limit, greater_than: 0, less_than_or_equal_to: 10_000)
  end
end
