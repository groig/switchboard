defmodule Switchboard.TimeZones do
  @moduledoc """
  IANA time zone helpers, backed by the `tz` database.
  """

  @doc "Whether `tz` is a known IANA time zone name."
  def valid?(tz) when is_binary(tz) do
    match?({:ok, _}, DateTime.now(tz))
  end

  def valid?(_), do: false

  @doc """
  All canonical zone names, sorted, for pickers.

  Read once from the `zone1970.tab` that ships with the `tz` package, then cached.
  """
  def all do
    case :persistent_term.get({__MODULE__, :all}, nil) do
      nil ->
        zones = load_zones()
        :persistent_term.put({__MODULE__, :all}, zones)
        zones

      zones ->
        zones
    end
  end

  defp load_zones do
    :tz
    |> :code.priv_dir()
    |> Path.join("tzdata*/zone1970.tab")
    |> Path.wildcard()
    |> Enum.sort()
    |> List.last()
    |> case do
      nil ->
        ["UTC"]

      path ->
        zones =
          for line <- File.stream!(path),
              not String.starts_with?(line, "#"),
              [_codes, _coords, zone | _] <- [String.split(line, "\t")],
              do: String.trim(zone)

        Enum.sort(["UTC" | zones])
    end
  end

  @doc "Shifts a UTC datetime into `tz`, falling back to UTC on unknown zones."
  def shift(%DateTime{} = dt, tz) when is_binary(tz) do
    case DateTime.shift_zone(dt, tz) do
      {:ok, shifted} -> shifted
      {:error, _} -> dt
    end
  end

  def shift(%DateTime{} = dt, _), do: dt

  def shift(%NaiveDateTime{} = ndt, tz), do: ndt |> DateTime.from_naive!("Etc/UTC") |> shift(tz)
end
