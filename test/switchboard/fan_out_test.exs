defmodule Switchboard.FanOutTest do
  use ExUnit.Case, async: true

  alias Switchboard.FanOut

  @tag :capture_log
  test "a slow or crashing entry gives a partial result within the budget" do
    started = System.monotonic_time(:millisecond)

    results =
      FanOut.run(
        [
          {:fast, :plane, fn -> {:ok, 1} end},
          {:slow, :argus, fn -> Process.sleep(5_000) end},
          {:boom, :outline, fn -> raise "boom" end}
        ],
        timeout: 200
      )

    elapsed = System.monotonic_time(:millisecond) - started

    assert results.fast == {:ok, 1}
    assert results.slow == {:error, :timeout}
    assert results.boom == {:error, :crashed}
    assert elapsed < 1_000
  end

  test "budgets are capped by config in tests" do
    assert FanOut.budget(9_000) == 600
    assert FanOut.budget(100) == 100
  end
end
