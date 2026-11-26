defmodule Switchboard.Watches do
  @moduledoc """
  Watches: "DM me in Rocket.Chat when this finishes" (CI runs, Plane work items, releases).

  Watches live in Postgres (`watches`) and are checked by Oban jobs, so they survive restarts
  and deploys:

    * `Watches.CiPoll` - one job per CI watch, rescheduling itself with backoff (1 to 5 min);
      a Forgejo webhook only moves it earlier (`Watches.Hint`);
    * `Watches.Sweep` - every minute (Oban cron, so one node): expires watches, re-creates
      missing CI jobs, reads the releases feed once for everyone, and queues `Watches.TaskPoll`
      (one job per person, every 5 minutes, through their own Plane key);
    * `Watches.Deliver` - sends one notice.

  **No double notices.** A notice is decided by a conditional update (`status = 'active'` and
  `notified_at IS NULL`), in the same transaction as the insert of a unique `Deliver` job. Two
  nodes, a retry or a redeploy can't pass that update twice, and `Deliver` itself marks the send
  before calling Rocket.Chat (`Watches.Deliver`).

  Every check runs with the owner's own credentials; notices go only to the owner, from the bot
  user (`Switchboard.RocketChat.notify/2`).
  """
  import Ecto.Query

  alias Switchboard.{Audit, Controls, Repo, Scope}
  alias Switchboard.Accounts.User
  alias Switchboard.Watches.{CiPoll, Deliver, Watch}

  @default_hours 24
  @max_hours 7 * 24
  @recent_days 14

  def default_hours, do: @default_hours
  def max_hours, do: @max_hours

  @doc "Active watches a person may have at once (config `:max_active`, default 20)."
  def max_active,
    do: Application.get_env(:switchboard, __MODULE__, []) |> Keyword.get(:max_active, 20)

  @doc "The scope background checks run with: the owner, through no client."
  def scope_for(%User{} = user), do: Scope.for_user(user, client_name: "watch")

  ## Creating

  @doc """
  Creates a watch for the scope's user. `attrs`: `:kind`, `:target`, `:subject`, `:options`,
  `:hours` (1 to #{@max_hours}, default #{@default_hours}) and `:state` (what the creation check
  saw). Refuses when watches are paused, when the person has `max_active/0` active watches, or
  when the same thing is already watched (`{:error, {:duplicate, watch}}`).
  """
  def create(%Scope{user: user}, attrs) do
    hours = attrs |> Map.get(:hours, @default_hours) |> max(1) |> min(@max_hours)
    now = DateTime.utc_now(:second)

    cond do
      Controls.watches_paused?() ->
        {:error, :paused}

      dup = duplicate(user, attrs) ->
        {:error, {:duplicate, dup}}

      active_count(user) >= max_active() ->
        {:error, :limit}

      true ->
        Repo.transact(fn ->
          watch =
            Repo.insert!(%Watch{
              user_id: user.id,
              kind: attrs.kind,
              target: attrs.target,
              subject: attrs.subject,
              options: Map.get(attrs, :options, %{}),
              last_state: Map.get(attrs, :state, %{}),
              expires_at: DateTime.add(now, hours * 3600),
              last_checked_at: now
            })

          if watch.kind == "ci", do: Oban.insert!(CiPoll.new_for(watch, 60))
          {:ok, watch}
        end)
    end
  end

  defp duplicate(user, attrs) do
    from(w in Watch,
      where:
        w.user_id == ^user.id and w.status == "active" and w.kind == ^attrs.kind and
          w.subject == ^attrs.subject
    )
    |> Repo.all()
    |> Enum.find(&(&1.target == attrs.target))
  end

  ## Reading (always the person's own)

  def active_count(%User{id: id}),
    do: Repo.aggregate(from(w in Watch, where: w.user_id == ^id and w.status == "active"), :count)

  @doc "The person's active watches and those that ended in the last #{@recent_days} days."
  def list(%User{id: id}, limit \\ 50) do
    since = DateTime.add(DateTime.utc_now(), -@recent_days * 86_400)

    from(w in Watch,
      where: w.user_id == ^id and (w.status == "active" or w.updated_at > ^since),
      order_by: [desc: w.status == "active", desc: w.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "One of the person's own watches, by id; `nil` for anyone else's or an invalid id."
  def get_own(%User{id: user_id}, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get_by(Watch, id: uuid, user_id: user_id)
      :error -> nil
    end
  end

  def get_own(_user, _id), do: nil

  @doc "Active watches per person (admin): `%{user_id => count}`."
  def active_counts do
    from(w in Watch,
      where: w.status == "active",
      group_by: w.user_id,
      select: {w.user_id, count()}
    )
    |> Repo.all()
    |> Map.new()
  end

  def get(id), do: Repo.get(Watch, id) |> Repo.preload(:user)

  @doc "Active watches of a kind (and optionally a subject), with their owners."
  def active(kind, subject \\ nil) do
    query = from(w in Watch, where: w.status == "active" and w.kind == ^kind, preload: :user)
    query = if subject, do: where(query, [w], w.subject == ^subject), else: query
    Repo.all(query)
  end

  ## Cancelling

  @doc """
  Cancels one of the scope's own active watches. `via: :web` records a web audit row (tool
  calls are audited by `Tools.run/3`).
  """
  def cancel(%Scope{user: user} = scope, id, opts \\ []) do
    with %Watch{} = watch <- get_own(user, id) || {:error, :not_found},
         true <- watch.status == "active" || {:error, :not_active} do
      now = DateTime.utc_now(:second)

      {n, _} =
        from(w in Watch, where: w.id == ^watch.id and w.status == "active")
        |> Repo.update_all(
          set: [status: "cancelled", end_reason: "cancelled", ended_at: now, updated_at: now]
        )

      if n == 1 do
        if opts[:via] == :web,
          do: Audit.log_web(scope, "watch.cancelled", %{kind: watch.kind, target: watch.target})

        {:ok, %{watch | status: "cancelled", end_reason: "cancelled", ended_at: now}}
      else
        {:error, :not_active}
      end
    end
  end

  ## Transitions (from the pollers)

  @doc "Records a check that changed nothing worth a notice."
  def checked(%Watch{} = watch, state \\ nil) do
    now = DateTime.utc_now(:second)
    set = [last_checked_at: now, updated_at: now] ++ if(state, do: [last_state: state], else: [])

    from(w in Watch, where: w.id == ^watch.id and w.status == "active")
    |> Repo.update_all(set: set, inc: [checks: 1])

    :ok
  end

  @doc """
  The thing happened: records `state`, marks the notice as decided and queues it, once.
  `health: true` keeps the watch active for the release's health follow-up, until `until`.
  Returns `:notified` or `:already` (another node or job got there first).
  """
  def notify(%Watch{} = watch, state, opts \\ []) do
    now = DateTime.utc_now(:second)

    set =
      if opts[:health] do
        until = opts[:until] || watch.expires_at

        expires =
          if DateTime.compare(until, watch.expires_at) == :gt, do: until, else: watch.expires_at

        [last_state: state, notified_at: now, expires_at: expires]
      else
        [
          last_state: state,
          notified_at: now,
          status: "fired",
          end_reason: "notified",
          ended_at: now
        ]
      end

    decide(watch, set ++ [last_checked_at: now, updated_at: now], "result")
  end

  @doc "The release's health window ended: the follow-up notice, once."
  def notify_health(%Watch{} = watch, state) do
    now = DateTime.utc_now(:second)

    {:ok, result} =
      Repo.transact(fn ->
        {n, _} =
          from(w in Watch,
            where:
              w.id == ^watch.id and w.status == "active" and not is_nil(w.notified_at) and
                is_nil(w.health_notified_at)
          )
          |> Repo.update_all(
            set: [
              last_state: state,
              health_notified_at: now,
              status: "fired",
              end_reason: "notified",
              ended_at: now,
              updated_at: now
            ]
          )

        if n == 1 do
          Oban.insert!(Deliver.new(%{watch_id: watch.id, notice: "health"}))
          {:ok, :notified}
        else
          {:ok, :already}
        end
      end)

    result
  end

  @doc "Ends a watch without a notice (e.g. CI passed and it was `only_on_failure`)."
  def finish_quietly(%Watch{} = watch, state, reason) do
    now = DateTime.utc_now(:second)

    from(w in Watch, where: w.id == ^watch.id and w.status == "active")
    |> Repo.update_all(
      set: [
        last_state: state,
        status: "fired",
        end_reason: reason,
        ended_at: now,
        last_checked_at: now,
        updated_at: now
      ]
    )

    :ok
  end

  @doc """
  The watch can't work any more (`reason`: `connection_missing`, `connection_rejected`,
  `access_lost`, `not_found`) or ran out of time (`timed_out`): it expires with one final notice,
  unless it already sent its notice (a release waiting for health just ends).
  """
  def stop(%Watch{} = watch, reason) when is_binary(reason) do
    now = DateTime.utc_now(:second)
    base = [status: "expired", end_reason: reason, ended_at: now, updated_at: now]

    if watch.notified_at do
      from(w in Watch, where: w.id == ^watch.id and w.status == "active")
      |> Repo.update_all(set: base)

      :already
    else
      decide(watch, base ++ [notified_at: now], "result")
    end
  end

  # The conditional update and the job insert commit together, or neither does.
  defp decide(watch, set, notice) do
    {:ok, result} =
      Repo.transact(fn ->
        {n, _} =
          from(w in Watch,
            where: w.id == ^watch.id and w.status == "active" and is_nil(w.notified_at)
          )
          |> Repo.update_all(set: set)

        if n == 1 do
          Oban.insert!(Deliver.new(%{watch_id: watch.id, notice: notice}))
          {:ok, :notified}
        else
          {:ok, :already}
        end
      end)

    result
  end

  @doc "Expires every active watch past its time (with the final notice). Returns how many."
  def expire_due(now \\ DateTime.utc_now()) do
    from(w in Watch, where: w.status == "active" and w.expires_at <= ^now)
    |> Repo.all()
    |> Enum.map(&stop(&1, "timed_out"))
    |> length()
  end
end
