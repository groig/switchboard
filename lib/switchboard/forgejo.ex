defmodule Switchboard.Forgejo do
  @moduledoc """
  Read-only client for Forgejo's API, with the caller's own sign-in token.

  **Read-only by construction.** The token from sign-in can do anything the person can in
  Forgejo (Forgejo 16 doesn't enforce OAuth scopes), so this module only ever sends `GET`:
  `get/3` fixes the method, and there is no other request function. Tests assert every request
  any Forgejo tool makes is a `GET`.

  CI notes from the real instance: job logs mark each step with `⭐ Run Main <step>`, a failing
  step ends with `⚙️ [runner]: exitcode '1': failure`, and the log ends with `🏁 Job failed`.
  """

  alias Switchboard.Upstreams

  @doc "GET `path` (under `/api/v1`) as the scope's user."
  def get(scope, path, params \\ []) do
    with {:ok, token} <- Upstreams.credential(scope, :forgejo) do
      Upstreams.request(:forgejo,
        method: :get,
        url: "/api/v1" <> path,
        params: params,
        auth: {:bearer, token}
      )
      |> Upstreams.body()
    end
  end

  def base_url, do: Upstreams.base_url(:forgejo)

  @doc "Splits `owner/repo`; `{:error, :invalid_repo}` otherwise."
  def parse_repo(repo) when is_binary(repo) do
    case String.split(String.trim(repo), "/") do
      [owner, name] when owner != "" and name != "" ->
        if Enum.all?([owner, name], &(&1 =~ ~r/^[\w.\-]+$/)),
          do: {:ok, owner, name},
          else: {:error, :invalid_repo}

      _ ->
        {:error, :invalid_repo}
    end
  end

  def parse_repo(_), do: {:error, :invalid_repo}

  @doc "Pull requests across repos (issue search), e.g. `created: true` or `q: \"PROJ-123\"`."
  def search_prs(scope, params) do
    params = Keyword.merge([type: "pulls", limit: 20], params)
    get(scope, "/repos/issues/search", params)
  end

  def pull(scope, owner, repo, number), do: get(scope, "/repos/#{owner}/#{repo}/pulls/#{number}")

  def reviews(scope, owner, repo, number),
    do: get(scope, "/repos/#{owner}/#{repo}/pulls/#{number}/reviews", limit: 50)

  def pull_commits(scope, owner, repo, number),
    do:
      get(scope, "/repos/#{owner}/#{repo}/pulls/#{number}/commits",
        limit: 50,
        verification: false,
        files: false
      )

  @doc "Combined commit status (CI checks) for a ref."
  def status(scope, owner, repo, ref),
    do: get(scope, "/repos/#{owner}/#{repo}/commits/#{ref}/status", limit: 50)

  @doc "Actions runs, filtered by `head_sha`, `run_number`, `status`..."
  def runs(scope, owner, repo, params),
    do: get(scope, "/repos/#{owner}/#{repo}/actions/runs", Keyword.merge([limit: 10], params))

  def run(scope, owner, repo, id), do: get(scope, "/repos/#{owner}/#{repo}/actions/runs/#{id}")

  @doc "A branch and its head commit (`commit.id`). Branch names may contain slashes."
  def branch(scope, owner, repo, branch) do
    path =
      branch
      |> String.split("/")
      |> Enum.map_join("/", fn seg -> URI.encode(seg, &URI.char_unreserved?/1) end)

    get(scope, "/repos/#{owner}/#{repo}/branches/#{path}")
  end

  def jobs(scope, owner, repo, run_id),
    do: get(scope, "/repos/#{owner}/#{repo}/actions/runs/#{run_id}/jobs")

  @doc "A job's plaintext log."
  def job_log(scope, owner, repo, job_id),
    do: get(scope, "/repos/#{owner}/#{repo}/actions/jobs/#{job_id}/logs")

  @doc "Recently updated repos the person contributes to."
  def my_repos(scope, uid, limit \\ 5),
    do: get(scope, "/repos/search", uid: uid, sort: "updated", order: "desc", limit: limit)

  @doc "Recent commits of a repo with their changed files."
  def commits(scope, owner, repo, limit \\ 30),
    do:
      get(scope, "/repos/#{owner}/#{repo}/commits",
        limit: limit,
        files: true,
        stat: false,
        verification: false
      )

  ## CI logs

  @doc """
  The failed step and the tail of a job log: `%{step: name | nil, tail: text}`. Timestamps are
  dropped, secrets scrubbed (`scrub/1`), and the tail ends at the step's failure line.
  """
  def failure_tail(log, lines \\ 60) do
    rows = log |> String.split("\n") |> Enum.map(&strip_timestamp/1)

    fail_at =
      Enum.find_index(rows, &(&1 =~ ~r/\[runner\]: exitcode '\d+': failure/)) ||
        Enum.find_index(rows, &(&1 =~ ~r/Job failed/)) || length(rows)

    before = Enum.take(rows, fail_at)

    {step, step_at} =
      before
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value({nil, 0}, fn {row, i} ->
        case Regex.run(~r/⭐ Run (?:Main |Pre |Post )?(.+)$/u, row) do
          [_, name] -> {String.trim(name), i + 1}
          _ -> nil
        end
      end)

    tail =
      before
      |> Enum.drop(step_at)
      |> Enum.reject(&(&1 =~ ~r/^##\[(end)?group\]/))
      |> Enum.take(-lines)
      |> Enum.join("\n")
      |> scrub()

    %{step: step, tail: tail}
  end

  defp strip_timestamp(line),
    do: String.replace(line, ~r/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z\s?/, "")

  @doc """
  Removes secrets from log text: tokens with known prefixes, JWTs, `key=value` credentials,
  credentials in URLs, bearer headers and private key blocks.
  """
  def scrub(text) do
    text
    |> String.replace(
      ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/s,
      "[REDACTED PRIVATE KEY]"
    )
    |> String.replace(~r/\b(Bearer|token|Basic)\s+[A-Za-z0-9._~+\/=-]{12,}/i, "\\1 [REDACTED]")
    |> String.replace(
      ~r/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/,
      "[REDACTED JWT]"
    )
    |> String.replace(
      ~r/\b(gh[pousr]_[A-Za-z0-9]{20,}|glpat-[A-Za-z0-9_-]{20,}|xox[abpr]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|argus_[A-Za-z0-9_-]{16,}|ol_api_[A-Za-z0-9]{20,}|sbat_[\w-]{20,}|sbrt_[\w-]{20,}|sb_[\w-]{20,})\b/,
      "[REDACTED]"
    )
    |> String.replace(~r/(https?:\/\/)[^\/\s:@]+:[^\/\s@]+@/, "\\1[REDACTED]@")
    |> String.replace(
      ~r/\b([A-Za-z0-9_]*(?:PASSWORD|PASSWD|SECRET|TOKEN|API_KEY|APIKEY|ACCESS_KEY|PRIVATE_KEY|CREDENTIALS?)[A-Za-z0-9_]*)(\s*[=:]\s*)("[^"]*"|'[^']*'|\S+)/i,
      "\\1\\2[REDACTED]"
    )
  end
end
