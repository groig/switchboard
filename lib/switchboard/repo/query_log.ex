defmodule Switchboard.Repo.QueryLog do
  @moduledoc """
  The SQL query log, without parameter values.

  Ecto's own query log prints every parameter, including plaintext secrets before `cloak_ecto`
  encrypts them. The repo runs with `log: false`; this handler logs the source table, the SQL
  text (placeholders only) and the time at `:debug`.
  """
  require Logger

  @handler "switchboard-query-log"

  def attach do
    :telemetry.attach(@handler, [:switchboard, :repo, :query], &__MODULE__.handle_event/4, nil)
  end

  @doc false
  def handle_event(_event, measurements, metadata, _config) do
    Logger.debug(fn ->
      us = System.convert_time_unit(measurements[:total_time] || 0, :native, :microsecond)
      status = if match?({:ok, _}, metadata[:result]), do: "OK", else: "ERROR"

      [
        "QUERY ",
        status,
        " source=",
        inspect(metadata[:source]),
        " ",
        Integer.to_string(div(us, 1000)),
        "ms\n",
        metadata[:query] || ""
      ]
    end)
  end
end
