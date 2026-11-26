defmodule Switchboard.FanOut do
  @moduledoc """
  Runs upstream calls concurrently with a time budget, for the cross-system tools.

      FanOut.run([
        {:plane, :plane, fn -> Plane.my_items(...) end},
        {:prs, :forgejo, fn -> Forgejo.my_prs(...) end}
      ], timeout: 8_000)
      #=> %{plane: {:ok, ...}, prs: {:error, :timeout}}

  Each entry is `{key, system, fun}`. Every task gets the same deadline; one that misses it is
  killed and reported as `{:error, :timeout}` (its upstream slot is released by the guard), one
  that raises as `{:error, :crashed}`. The call never waits longer than the budget, and the
  others' results are kept. `note/2` turns failures into the one-line notes tools append.
  """

  require Logger

  @default_timeout 8_000

  @doc """
  A tool's time budget, capped by `config :switchboard, Switchboard.FanOut, max_timeout:` (tests
  use a short one so slow-upstream cases finish fast).
  """
  def budget(ms) do
    case Application.get_env(:switchboard, __MODULE__, [])[:max_timeout] do
      max when is_integer(max) -> min(ms, max)
      _ -> ms
    end
  end

  @spec run([{term(), atom(), (-> term())}], keyword()) :: %{term() => term()}
  def run(entries, opts \\ []) do
    timeout = budget(Keyword.get(opts, :timeout, @default_timeout))
    Enum.each(entries, fn {_key, system, _fun} -> Switchboard.Tools.note_upstream(system) end)

    Switchboard.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      entries,
      fn {_key, _system, fun} -> fun.() end,
      timeout: timeout,
      on_timeout: :kill_task,
      max_concurrency: max(length(entries), 1),
      ordered: true
    )
    |> Enum.zip(entries)
    |> Map.new(fn
      {{:ok, result}, {key, _system, _fun}} ->
        {key, result}

      {{:exit, :timeout}, {key, _system, _fun}} ->
        {key, {:error, :timeout}}

      {{:exit, reason}, {key, system, _fun}} ->
        Logger.error("Fan-out task #{inspect(key)} (#{system}) crashed: #{inspect(reason)}")
        {key, {:error, :crashed}}
    end)
  end
end
