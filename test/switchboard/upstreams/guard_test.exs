defmodule Switchboard.Upstreams.GuardTest do
  # Global state (one guard per node): synchronous, and each test sets its own limits.
  use ExUnit.Case, async: false

  alias Switchboard.Upstreams.Guard

  setup do
    original = Application.get_env(:switchboard, Switchboard.Upstreams)
    Guard.reset()

    on_exit(fn ->
      Application.put_env(:switchboard, Switchboard.Upstreams, original)
      Guard.reset()
    end)

    :ok
  end

  defp limits(opts) do
    config = Application.get_env(:switchboard, Switchboard.Upstreams)
    Application.put_env(:switchboard, Switchboard.Upstreams, Keyword.put(config, :guard, opts))
  end

  test "at most max_concurrency requests run at once; the rest wait, then get :busy" do
    limits(max_concurrency: 2, acquire_timeout: 150, threshold: 100, cooldown: 1_000)
    test = self()

    holders =
      for i <- 1..2 do
        spawn(fn ->
          Guard.run(:plane, fn ->
            send(test, {:holding, i})
            receive do: (:go -> {:success, :ok})
          end)
        end)
      end

    assert_receive {:holding, 1}
    assert_receive {:holding, 2}

    # A third caller queues and gives up after acquire_timeout.
    assert {:error, :busy} = Guard.run(:plane, fn -> {:success, :never} end)

    # A queued caller is let in when a slot frees.
    waiter = Task.async(fn -> Guard.run(:plane, fn -> {:success, :third} end) end)
    Process.sleep(20)
    send(hd(holders), :go)
    assert Task.await(waiter) == :third

    # Other systems are independent.
    assert :ok = Guard.run(:argus, fn -> {:success, :ok} end)
  end

  test "a holder that dies (e.g. a killed fan-out task) releases its slot" do
    limits(max_concurrency: 1, acquire_timeout: 500, threshold: 100, cooldown: 1_000)

    pid = spawn(fn -> Guard.run(:plane, fn -> Process.sleep(:infinity) end) end)
    Process.sleep(20)
    Process.exit(pid, :kill)

    assert :ok = Guard.run(:plane, fn -> {:success, :ok} end)
  end

  test "consecutive failures open the breaker; it fails fast, then half-opens after the cooldown" do
    limits(max_concurrency: 10, acquire_timeout: 100, threshold: 3, cooldown: 100)

    for _ <- 1..3, do: Guard.run(:argus, fn -> {:failure, {:error, :timeout}} end)

    assert Guard.status()[:argus] == :open
    assert {:error, :circuit_open} = Guard.run(:argus, fn -> raise "must not run" end)

    Process.sleep(120)
    assert Guard.status()[:argus] == :half_open
    # A failed trial opens it again...
    Guard.run(:argus, fn -> {:failure, {:error, :timeout}} end)
    assert {:error, :circuit_open} = Guard.run(:argus, fn -> raise "must not run" end)

    # ...a successful one closes it.
    Process.sleep(120)
    assert :ok = Guard.run(:argus, fn -> {:success, :ok} end)
    assert Guard.status()[:argus] == :closed
  end

  test "successes reset the failure count" do
    limits(max_concurrency: 10, acquire_timeout: 100, threshold: 2, cooldown: 1_000)
    Guard.run(:outline, fn -> {:failure, :x} end)
    Guard.run(:outline, fn -> {:success, :ok} end)
    Guard.run(:outline, fn -> {:failure, :x} end)
    assert Guard.status()[:outline] == :closed
  end
end
