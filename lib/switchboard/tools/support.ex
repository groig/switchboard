defmodule Switchboard.Tools.Support do
  @moduledoc """
  Shared helpers for tool modules: credentials, one-line problems, untrusted blocks, Markdown,
  times in the person's zone. `use Switchboard.Tools.Support` imports them.
  """

  alias Switchboard.{Markdown, Scope, TimeZones, Untrusted, Upstreams}

  defmacro __using__(_) do
    quote do
      @behaviour Switchboard.Tool
      import Switchboard.Tools.Support
      alias Switchboard.Markdown
    end
  end

  @doc "The caller's credential, or `{:error, line}` explaining why it's missing."
  def cred(%Scope{} = scope, system) do
    case Upstreams.credential(scope, system) do
      {:ok, cred} -> {:ok, cred}
      {:error, reason} -> {:error, Upstreams.problem(system, reason)}
    end
  end

  @doc "Turns an upstream error into the line the agent sees."
  def problem(system, reason), do: Upstreams.problem(system, reason)

  @doc "Wraps upstream text as untrusted."
  def untrusted(text, source, attrs \\ []), do: Untrusted.wrap(text, source, attrs)

  def cell(value, max \\ 80), do: Markdown.cell(value, max)
  def table(headers, rows), do: Markdown.table(headers, rows)

  @doc "A timestamp in the person's time zone: `2026-11-26 15:05 (Europe/Madrid)`."
  def time(nil, _scope), do: "–"

  def time(value, %Scope{user: user}) do
    case to_datetime(value) do
      %DateTime{} = dt ->
        local = TimeZones.shift(dt, user.time_zone)
        Calendar.strftime(local, "%Y-%m-%d %H:%M") <> " (#{user.time_zone})"

      nil ->
        to_string(value)
    end
  end

  @doc "Parses ISO 8601 strings; passes DateTimes through; nil otherwise."
  def to_datetime(%DateTime{} = dt), do: dt

  def to_datetime(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  def to_datetime(_), do: nil

  @doc "Appends notes (one line each) under a `Notes` heading, when there are any."
  def with_notes(markdown, []), do: markdown

  def with_notes(markdown, notes) do
    markdown <> "\n\n**Notes**\n" <> Enum.map_join(notes, "\n", &("- " <> &1))
  end

  @doc """
  The names agents use for a task id (`PROJ-123`) when the tool calls it `real`, e.g.
  `identifier` or `task` for `id` (`Switchboard.Tool.aliases/0`).
  """
  def task_aliases(real) do
    ~w(id identifier task task_id key issue issue_id item work_item)
    |> List.delete(real)
    |> Map.new(&{&1, real})
  end

  @doc "Validates a bounded integer argument."
  def int_arg(args, key, default, min, max) do
    case Map.get(args, key, default) do
      n when is_integer(n) -> {:ok, n |> max(min) |> min(max)}
      _ -> {:error, "#{key} must be an integer"}
    end
  end
end
