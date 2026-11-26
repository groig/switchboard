defmodule Switchboard.Markdown do
  @moduledoc "Helpers for compact, model-friendly Markdown: table cells, caps, HTML to text."

  @doc "A table cell: one line, pipes escaped, capped."
  def cell(value, max \\ 80)
  def cell(nil, _max), do: "–"
  def cell("", _max), do: "–"

  def cell(value, max) do
    value
    |> to_string()
    |> String.replace(~r/\s+/u, " ")
    |> String.replace("|", "\\|")
    |> String.trim()
    |> truncate(max)
  end

  @doc "A Markdown table from a header list and rows (lists of cells, already formatted)."
  def table(headers, rows) do
    head = "| " <> Enum.join(headers, " | ") <> " |"
    sep = "|" <> String.duplicate("---|", length(headers))
    body = Enum.map(rows, &("| " <> Enum.join(&1, " | ") <> " |"))
    Enum.join([head, sep | body], "\n")
  end

  def truncate(s, max) do
    if String.length(s) > max, do: String.slice(s, 0, max - 1) <> "…", else: s
  end

  @doc "Caps a whole result, cutting at a line boundary and saying so."
  def cap(text, max \\ 12_000) do
    if String.length(text) <= max do
      text
    else
      cut = String.slice(text, 0, max)
      cut = String.slice(cut, 0, cut |> :binary.matches("\n") |> List.last({max, 0}) |> elem(0))
      cut <> "\n\n… (truncated; narrow the request for more)"
    end
  end

  @doc "Plain text from Plane/Outline HTML (good enough for models; not a sanitizer)."
  def html_to_text(nil), do: ""

  def html_to_text(html) do
    html
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<\/(p|div|li|h\d|tr|blockquote|pre)>/i, "\n")
    |> String.replace(~r/<li[^>]*>/i, "- ")
    |> String.replace(~r/<[^>]+>/, "")
    |> unescape()
    |> String.replace(~r/[ \t]+\n/, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp unescape(s) do
    s
    |> String.replace("&nbsp;", " ")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
  end

  @doc "A date (`2026-11-26`) from an ISO 8601 string or DateTime, or `–`."
  def date(nil), do: "–"
  def date(%DateTime{} = dt), do: Date.to_iso8601(DateTime.to_date(dt))
  def date(s) when is_binary(s), do: String.slice(s, 0, 10)

  @doc "A UTC timestamp to the minute: `2026-11-26 14:05 UTC`."
  def datetime(nil), do: "–"

  def datetime(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> datetime(dt)
      _ -> s
    end
  end

  def datetime(%DateTime{} = dt),
    do: Calendar.strftime(DateTime.shift_zone!(dt, "Etc/UTC"), "%Y-%m-%d %H:%M UTC")
end
