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

  @doc "Successful releases that shipped a task (by id), newest first."
  def shipping(task_id, releases) do
    id = String.upcase(task_id)

    Enum.filter(releases, fn r ->
      r["status"] == "success" and
        Enum.any?(r["tasks"] || [], &(String.upcase(&1["id"] || "") == id))
    end)
  end
end
