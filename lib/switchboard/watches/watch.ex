defmodule Switchboard.Watches.Watch do
  @moduledoc """
  One watch: "DM me in Rocket.Chat when this finishes". See `Switchboard.Watches`.

    * `kind` - `ci`, `task` or `release`;
    * `target` - what it watches (`%{"repo", "pr" | "branch" | "run"}`, `%{"id"}`, `%{"repo"}`);
    * `subject` - the lookup key (lowercase `owner/name`, `PROJ-123`, the release repo);
    * `status` - `active`, `fired`, `expired` or `cancelled`, with an `end_reason`;
    * `last_state` - what the last check saw (statuses, names, links; never message text);
    * `notified_at` / `health_notified_at` - set once, in the database, before a notice goes out.
  """
  use Ecto.Schema

  alias Switchboard.Accounts.User

  @kinds ~w(ci task release)
  @statuses ~w(active fired expired cancelled)

  def kinds, do: @kinds
  def statuses, do: @statuses

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "watches" do
    belongs_to :user, User
    field :kind, :string
    field :target, :map
    field :subject, :string
    field :options, :map, default: %{}
    field :status, :string, default: "active"
    field :expires_at, :utc_datetime
    field :last_state, :map, default: %{}
    field :end_reason, :string
    field :ended_at, :utc_datetime
    field :notified_at, :utc_datetime
    field :health_notified_at, :utc_datetime
    field :deliveries, :map, default: %{}
    field :checks, :integer, default: 0
    field :last_checked_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "A short label for what is watched: `demo/app#42`, `demo/app main`, `DEMO-12`, `web`."
  def label(%__MODULE__{kind: "ci", target: t}) do
    cond do
      t["pr"] -> "#{t["repo"]}##{t["pr"]}"
      t["run"] -> "#{t["repo"]} run ##{t["run"]}"
      t["branch"] -> "#{t["repo"]} #{t["branch"]}"
      true -> t["repo"]
    end
  end

  def label(%__MODULE__{kind: "task", target: %{"id" => id}}), do: id
  def label(%__MODULE__{kind: "release", target: %{"repo" => repo}}), do: repo
end
