defmodule Switchboard.Argus do
  @moduledoc """
  Read-only client for Argus's agent API (Markdown), with the caller's own `argus_` token.

  Issue text is trimmed (`trim_issue/2`, the same way the release bot trims it for triage): the User,
  Request, SDK, Contexts, Extra and Query Breadcrumbs sections, local variables and URL query
  strings are dropped, and the length is capped.
  """

  alias Switchboard.Upstreams

  defp get(%{"token" => token}, path, params \\ []) do
    Upstreams.request(:argus,
      url: "/api/v1" <> path,
      params: params,
      auth: {:bearer, token},
      headers: [accept: "text/markdown"]
    )
    |> Upstreams.body()
  end

  def base_url, do: Upstreams.base_url(:argus)

  @doc "Who the token belongs to: `%{\"email\", \"name\", \"role\", \"teams\"}`."
  def me(cred) do
    with {:ok, text} <- get(cred, "/me") do
      fields =
        for line <- String.split(text, "\n"),
            [_, k, v] <- [Regex.run(~r/^(Email|Name|Role|Teams):\s*(.*)$/, String.trim(line))],
            into: %{},
            do: {String.downcase(k), String.trim(v)}

      teams =
        case fields["teams"] do
          nil -> []
          "none" -> []
          t -> t |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
        end

      {:ok, Map.put(fields, "teams", teams)}
    end
  end

  @doc "Projects the token can see: `[%{name, slug, team, unresolved}]`."
  def projects(cred) do
    with {:ok, text} <- get(cred, "/projects") do
      {:ok,
       for row <- table_rows(text), length(row) >= 4 do
         [name, slug, team, unresolved | _] = row

         %{
           "name" => name,
           "slug" => String.trim(slug, "`"),
           "team" => team,
           "unresolved" => parse_int(unresolved)
         }
       end}
    end
  end

  @doc """
  Issues of a project as parsed rows: `[%{id, title, level, status, events, last_seen,
  culprit, url}]`. `params`: `status`, `level`, `q`, `page`, `per_page`.
  """
  def issues(cred, slug, params \\ []) do
    with {:ok, text} <- get(cred, "/projects/#{URI.encode(slug)}/issues", params) do
      rows =
        for row <- table_rows(text), length(row) >= 8 do
          [id, title, level, status, events, last_seen, culprit, url | _] = row

          %{
            "id" => id,
            "title" => title,
            "level" => level,
            "status" => status,
            "events" => parse_int(events),
            "last_seen" => last_seen,
            "culprit" => culprit,
            "url" => link_target(url)
          }
        end

      {:ok, rows, text}
    end
  end

  @doc "One issue's full text (latest occurrence), trimmed."
  def issue(cred, slug, id, frames \\ "in_app") do
    with {:ok, text} <-
           get(cred, "/projects/#{URI.encode(slug)}/issues/#{URI.encode(id)}", frames: frames) do
      {:ok, trim_issue(text)}
    end
  end

  @doc "Resolves (`:resolve`) or ignores (`:ignore`) an issue. Returns Argus's Markdown answer."
  def change_status(%{"token" => token}, slug, id, action) when action in [:resolve, :ignore] do
    Upstreams.request(:argus,
      method: :post,
      url: "/api/v1/projects/#{URI.encode(slug)}/issues/#{URI.encode(id)}/#{action}",
      auth: {:bearer, token},
      headers: [accept: "text/markdown"]
    )
    |> Upstreams.body()
  end

  # Markdown table rows after the header and separator; cells trimmed.
  defp table_rows(text) do
    text
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "|"))
    |> Enum.drop(2)
    |> Enum.map(fn line ->
      line
      |> String.trim()
      |> String.trim_leading("|")
      |> String.trim_trailing("|")
      |> String.split(~r/(?<!\\)\|/)
      |> Enum.map(&String.trim/1)
    end)
  end

  defp link_target(cell) do
    case Regex.run(~r/\((https?:\/\/[^)\s]+)\)/, cell) do
      [_, url] -> url
      _ -> String.trim(cell)
    end
  end

  defp parse_int(s) do
    case Integer.parse(String.replace(to_string(s), ~r/[^\d]/, "")) do
      {n, _} -> n
      :error -> 0
    end
  end

  @dropped ~w(User Request SDK Contexts Extra) ++ ["Query Breadcrumbs"]
  @sections ["Argus Issue", "Selected Event", "Exceptions", "Tags" | @dropped]

  @doc "Trims issue text for agents (default cap 15 000 characters)."
  def trim_issue(text, max \\ 15_000) do
    {lines, _} =
      text
      |> String.split("\n")
      |> Enum.reduce({[], %{drop: false, vars: false, prev_blank: true}}, fn line, {out, st} ->
        trimmed = String.trim(line)
        drop = if st.prev_blank and trimmed in @sections, do: trimmed in @dropped, else: st.drop
        st = %{st | drop: drop, prev_blank: trimmed == ""}

        cond do
          drop -> {out, st}
          trimmed == "Local variables:" -> {out, %{st | vars: true}}
          st.vars and line =~ ~r/^\s/ -> {out, st}
          true -> {[strip_query(line) | out], %{st | vars: false}}
        end
      end)

    s =
      lines
      |> Enum.reverse()
      |> Enum.join("\n")
      |> String.replace(~r/\n{3,}/, "\n\n")
      |> String.trim()

    if String.length(s) > max, do: String.slice(s, 0, max) <> "\n… (truncated)", else: s
  end

  defp strip_query(line), do: String.replace(line, ~r/(https?:\/\/[^\s?#]+)[?#]\S*/, "\\1?…")
end
