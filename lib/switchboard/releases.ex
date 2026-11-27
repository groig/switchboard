defmodule Switchboard.Releases do
  @moduledoc """
  Production releases, as the release bot's release cards record them (the feed's shape is in
  `docs/ARCHITECTURE.md`).

  A behaviour with two adapters, chosen by config:

    * `Switchboard.Releases.HTTP` - `GET /releases` on the release bot with a service bearer token
      (read-only; the only service credential besides the Rocket.Chat bot);
    * `Switchboard.Releases.Fake` - built-in synthetic releases for development.

  Releases are maps with the feed's own (string) keys.
  """

  @callback list(params :: keyword()) :: {:ok, [map()]} | {:error, term()}

  defp adapter,
    do: Application.get_env(:switchboard, __MODULE__, [])[:adapter] || Switchboard.Releases.HTTP

  @doc "Releases, newest first. `repo:`, `since:` (DateTime), `limit:` (1-200)."
  def list(params \\ []) do
    params =
      params
      |> Keyword.update(:since, nil, &(&1 && DateTime.to_iso8601(&1)))
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    adapter().list(params)
  end

  @doc "The latest release of a repo (any status), or `{:error, :not_found}`."
  def latest(repo) do
    with {:ok, releases} <- list(repo: repo, limit: 1) do
      case releases do
        [r | _] -> {:ok, r}
        [] -> {:error, :not_found}
      end
    end
  end

  @doc "A release by name (branch), searching the last 90 days."
  def find(name, repo \\ nil) do
    with {:ok, releases} <- list(repo: repo, limit: 200) do
      case Enum.find(releases, &(&1["name"] == name)) do
        nil -> {:error, :not_found}
        r -> {:ok, r}
      end
    end
  end

  ## Matching what people type (shared by `release` and `watch_release`)

  @doc "Repo names in `releases` with their newest release, most recently released first."
  def repos(releases) do
    releases
    |> Enum.uniq_by(& &1["repo"])
    |> Enum.map(&%{repo: &1["repo"], latest: &1})
  end

  @doc """
  The repo someone meant, among those with releases in `releases`: the name itself, the name of
  an `owner/name` (release cards use the short name), case-insensitively, or a unique
  case-insensitive prefix. `{:ok, repo}`, `{:ambiguous, repos}` or `:unknown`.
  """
  def resolve_repo(releases, input) when is_binary(input) do
    input = String.trim(input)
    short = input |> String.trim_trailing("/") |> String.split("/") |> List.last() |> to_string()
    wanted = Enum.uniq([String.downcase(input), String.downcase(short)])
    names = releases |> Enum.map(& &1["repo"]) |> Enum.filter(&is_binary/1) |> Enum.uniq()

    exact = Enum.find(names, &(&1 in [input, short]))
    folded = Enum.filter(names, &(String.downcase(&1) in wanted))

    prefixed =
      if short == "",
        do: [],
        else:
          Enum.filter(names, &String.starts_with?(String.downcase(&1), String.downcase(short)))

    cond do
      exact -> {:ok, exact}
      match?([_], folded) -> {:ok, hd(folded)}
      match?([_], prefixed) -> {:ok, hd(prefixed)}
      prefixed != [] -> {:ambiguous, Enum.sort(prefixed)}
      folded != [] -> {:ambiguous, Enum.sort(folded)}
      true -> :unknown
    end
  end

  @doc """
  Release names close to what someone typed, newest first (at most 5): names containing it
  (case-insensitive; how a version like `27.1` or a date is usually given), then similar names.
  """
  def suggest_names(releases, input) when is_binary(input) do
    wanted = input |> String.trim() |> String.downcase()
    names = releases |> Enum.map(& &1["name"]) |> Enum.filter(&is_binary/1) |> Enum.uniq()

    containing =
      if String.length(wanted) >= 2,
        do: Enum.filter(names, &String.contains?(String.downcase(&1), wanted)),
        else: []

    similar =
      Enum.filter(names, &(String.jaro_distance(String.downcase(&1), wanted) >= 0.88))

    Enum.uniq(containing ++ similar) |> Enum.take(5)
  end

  @doc "Successful releases that shipped a task (by id), newest first."
  def shipping(task_id, releases) do
    id = String.upcase(task_id)

    Enum.filter(releases, fn r ->
      r["status"] == "success" and
        Enum.any?(r["tasks"] || [], &(String.upcase(&1["id"] || "") == id))
    end)
  end
end
