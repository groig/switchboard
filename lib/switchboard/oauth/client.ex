defmodule Switchboard.OAuth.Client do
  @moduledoc """
  An OAuth client: registered through DCR (`kind: "dcr"`) or known by its Client ID Metadata
  Document URL (`kind: "cimd"`, where `client_id` is the URL and the metadata is a cached copy).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "oauth_clients" do
    field :client_id, :string
    field :kind, :string
    field :client_name, :string
    field :client_uri, :string
    field :redirect_uris, {:array, :string}, default: []
    field :metadata, :map, default: %{}
    field :fetched_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(client, attrs) do
    client
    |> cast(attrs, [
      :client_id,
      :kind,
      :client_name,
      :client_uri,
      :redirect_uris,
      :metadata,
      :fetched_at
    ])
    |> validate_required([:client_id, :kind, :redirect_uris])
    |> validate_inclusion(:kind, ~w(dcr cimd))
    |> validate_length(:client_name, max: 200)
    |> validate_length(:redirect_uris, min: 1, max: 10)
    |> unique_constraint(:client_id)
  end
end
