defmodule Switchboard.Accounts.User do
  @moduledoc "A person who signed in with Forgejo."
  use Ecto.Schema
  import Ecto.Changeset

  @locales ~w(es en)
  @themes ~w(system light dark)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "users" do
    field :forgejo_id, :integer
    field :username, :string
    field :email, :string
    field :name, :string
    field :admin, :boolean, default: false
    field :locale, :string, default: "es"
    field :time_zone, :string, default: "Europe/Madrid"
    field :theme, :string, default: "system"
    field :session_version, :integer, default: 1
    field :last_login_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def locales, do: @locales

  @doc "Changeset for the identity Forgejo reports at login. Not for user input."
  def login_changeset(user, attrs) do
    user
    |> cast(attrs, [:forgejo_id, :username, :email, :name, :admin, :last_login_at])
    |> validate_required([:forgejo_id, :username])
    |> unique_constraint(:forgejo_id)
    |> unique_constraint(:username)
  end

  @doc "The settings a person changes on their profile page."
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:locale, :time_zone, :theme])
    |> validate_required([:locale, :time_zone, :theme])
    |> validate_inclusion(:locale, @locales)
    |> validate_inclusion(:theme, @themes)
    |> validate_change(:time_zone, fn :time_zone, tz ->
      if Switchboard.TimeZones.valid?(tz), do: [], else: [time_zone: "is not a valid time zone"]
    end)
  end

  def theme_changeset(user, theme) do
    user |> change(theme: theme) |> validate_inclusion(:theme, @themes)
  end

  @doc "The name to show: the full name, or the username."
  def display_name(%__MODULE__{name: name}) when is_binary(name) and name != "", do: name
  def display_name(%__MODULE__{username: username}), do: username

  @avatar_colors ~w(slate red orange amber green teal blue indigo violet pink)

  @doc "A stable avatar colour derived from the username."
  def avatar_color(%__MODULE__{username: username}) do
    Enum.at(@avatar_colors, :erlang.phash2(String.downcase(username), length(@avatar_colors)))
  end
end
