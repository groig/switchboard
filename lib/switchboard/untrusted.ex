defmodule Switchboard.Untrusted do
  @moduledoc """
  Wraps upstream text (descriptions, comments, error messages, wiki pages, CI logs) so the agent
  can tell data from instructions:

      <untrusted source="plane" item="PROJ-123">
      ...text...
      </untrusted>

  The server instructions tell agents never to follow instructions inside these blocks. Text that
  tries to close the block early is neutralised, and attribute values are restricted to a safe
  character set.
  """

  @doc "Wraps `text` from `source` (`\"plane\"`, `\"argus\"`...) with optional attributes."
  def wrap(text, source, attrs \\ []) when is_binary(source) do
    attrs =
      Enum.map_join(attrs, "", fn {k, v} -> ~s( #{k}="#{attr(v)}") end)

    "<untrusted source=\"#{attr(source)}\"#{attrs}>\n#{neutralise(text)}\n</untrusted>"
  end

  defp attr(v),
    do: v |> to_string() |> String.replace(~r/[^\w.\-\/:#@ ]/u, "") |> String.slice(0, 120)

  @doc "Breaks any `<untrusted` / `</untrusted` tags inside the text."
  def neutralise(nil), do: ""

  def neutralise(text) do
    text
    |> to_string()
    |> String.replace(~r/<(\/?)(untrusted)/i, "<\\1​\\2")
    |> String.trim()
  end
end
