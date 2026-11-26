defmodule SwitchboardWeb.Format do
  @moduledoc """
  Locale-aware formatting for numbers, durations, dates and relative times.

  The locale is the process's Gettext locale (set by `SwitchboardWeb.Locale`).
  Dates are shifted into the scope's time zone; everything is stored in UTC.
  """
  use Gettext, backend: SwitchboardWeb.Gettext

  alias Switchboard.Scope

  @months %{
    "en" => ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec),
    "es" => ~w(ene feb mar abr may jun jul ago sept oct nov dic)
  }

  defp locale, do: Gettext.get_locale(SwitchboardWeb.Gettext)

  ## Numbers

  @doc """
  Formats an integer or float with the locale's separators.

      en: 12,345.6   es: 12.345,6 (and 1234 without a separator, per CLDR)
  """
  def number(value, opts \\ [])
  def number(nil, _opts), do: "–"

  def number(value, opts) when is_integer(value) do
    group(Integer.to_string(abs(value)), value < 0, nil, opts)
  end

  def number(value, opts) when is_float(value) do
    decimals = Keyword.get(opts, :decimals, 1)
    [int, frac] = value |> abs() |> :erlang.float_to_binary(decimals: decimals) |> split_decimal()
    group(int, value < 0, frac, opts)
  end

  defp split_decimal(string) do
    case String.split(string, ".") do
      [int, frac] -> [int, frac]
      [int] -> [int, nil]
    end
  end

  defp group(int, negative?, frac, _opts) do
    {thousands, decimal, min_grouping} =
      case locale() do
        "es" -> {".", ",", 5}
        _ -> {",", ".", 4}
      end

    grouped =
      if String.length(int) >= min_grouping do
        int
        |> String.reverse()
        |> String.graphemes()
        |> Enum.chunk_every(3)
        |> Enum.map_join(thousands, &Enum.join/1)
        |> String.reverse()
      else
        int
      end

    sign = if negative?, do: "−", else: ""
    if frac in [nil, ""], do: sign <> grouped, else: sign <> grouped <> decimal <> frac
  end

  @doc "Formats a ratio (0..1) or percentage as `42 %` / `42%`."
  def percent(nil), do: "–"

  def percent(value) when is_number(value) do
    rounded = round(value)

    case locale() do
      "es" -> "#{number(rounded)} %"
      _ -> "#{number(rounded)}%"
    end
  end

  ## Durations

  @doc """
  A compact human duration from seconds: `45s`, `2m 05s`, `1h 03m`.
  """
  def duration(nil), do: "–"
  def duration(seconds) when is_float(seconds), do: duration(round(seconds))

  def duration(seconds) when is_integer(seconds) and seconds < 60,
    do: gettext("%{s}s", s: seconds)

  def duration(seconds) when is_integer(seconds) and seconds < 3600 do
    gettext("%{m}m %{s}s", m: div(seconds, 60), s: pad(rem(seconds, 60)))
  end

  def duration(seconds) when is_integer(seconds) do
    gettext("%{h}h %{m}m", h: div(seconds, 3600), m: pad(div(rem(seconds, 3600), 60)))
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  ## Dates

  @doc """
  Date and time in the scope's time zone: `24 Nov 2026, 14:05`. Says `UTC` when the zone
  couldn't be applied (no time zone database).
  """
  def datetime(nil, _scope), do: "–"

  def datetime(dt, scope) do
    tz = timezone(scope)
    local = Switchboard.TimeZones.shift(dt, tz)

    suffix =
      if local.time_zone == "Etc/UTC" and tz not in ["UTC", "Etc/UTC"], do: " UTC", else: ""

    "#{date_part(local)}, #{time(local)}#{suffix}"
  end

  @doc "Date in the scope's time zone: `24 Nov 2026`."
  def date(nil, _scope), do: "–"
  def date(dt, scope), do: dt |> Switchboard.TimeZones.shift(timezone(scope)) |> date_part()

  @doc "Time of day in the scope's time zone: `14:05`."
  def time_of_day(nil, _scope), do: "–"
  def time_of_day(dt, scope), do: dt |> Switchboard.TimeZones.shift(timezone(scope)) |> time()

  defp date_part(local) do
    month = @months |> Map.get(locale(), @months["en"]) |> Enum.at(local.month - 1)
    "#{local.day} #{month} #{local.year}"
  end

  defp time(local), do: "#{pad(local.hour)}:#{pad(local.minute)}"

  defp timezone(%Scope{user: %{time_zone: tz}}), do: tz
  defp timezone(tz) when is_binary(tz), do: tz
  defp timezone(_), do: "Etc/UTC"

  @doc """
  A relative time: "just now", "3 min ago", "5 h ago", "yesterday", then the
  date.
  """
  def relative(dt, scope, now \\ DateTime.utc_now())
  def relative(nil, _scope, _now), do: gettext("never")

  def relative(%NaiveDateTime{} = ndt, scope, now),
    do: relative(DateTime.from_naive!(ndt, "Etc/UTC"), scope, now)

  def relative(%DateTime{} = dt, scope, now) do
    seconds = DateTime.diff(now, dt)

    cond do
      seconds < 45 ->
        gettext("just now")

      seconds < 3600 ->
        minutes = max(1, div(seconds, 60))
        ngettext("%{count} min ago", "%{count} min ago", minutes)

      seconds < 86_400 ->
        hours = div(seconds, 3600)
        ngettext("%{count} h ago", "%{count} h ago", hours)

      seconds < 2 * 86_400 ->
        gettext("yesterday")

      seconds < 7 * 86_400 ->
        days = div(seconds, 86_400)
        ngettext("%{count} day ago", "%{count} days ago", days)

      true ->
        date(dt, scope)
    end
  end
end
