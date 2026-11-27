defmodule Switchboard.GitHub do
  @moduledoc """
  Read-only client for GitHub's REST API, with the caller's own token (the `github` connection,
  linked through the OAuth App flow in `Switchboard.GitHub.Login`).

  **Read-only by construction.** Classic OAuth Apps have no read-only scope for private
  repositories (`repo` is read and write; see `docs/SECURITY.md`), so this module only ever sends
  `GET`: `get/3` fixes the method and there is no other request function. Tests assert every
  request any tool makes to GitHub is a `GET`.

  **Same shapes as `Switchboard.Forgejo`.** The functions here have Forgejo's names and
  arguments and answer in the shapes the Forgejo tools already render (`Switchboard.Repos`
  picks the module): a search hit has `repository.full_name` and `pull_request.merged`, a
  combined status merges check runs and commit statuses into `state` + `statuses`, an Actions
  run has `index_in_repo` (the run id, as in its URL), `workflow_id` and a single `status`
  (`success`, `failure`, `cancelled`, `skipped`, `running`, `waiting`). Everything normalized
  carries `"host" => "github"`.

  **Rate limits.** A token has its own budget (5 000 requests an hour, shared with the person's
  other tools; search: 30 a minute). Requests send the stored ETag (a `304` doesn't count against
  the budget) and reuse the cached body. When GitHub says the budget is used up
  (`X-RateLimit-Remaining: 0` or `Retry-After`), further calls with that token fail fast until
  it resets, without asking GitHub.
  """

  alias Switchboard.{Cache, Forgejo, Upstreams}

  @api_version "2022-11-28"
  @etag_ttl :timer.minutes(10)
  @max_log 4_000_000

  ## Configuration

  defp config, do: Application.get_env(:switchboard, __MODULE__, [])

  @doc "Whether an OAuth App is configured (`GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET`)."
  def configured?, do: present?(config()[:client_id]) and present?(config()[:client_secret])

  @doc "The owners (users or orgs) whose repositories live on GitHub, lowercase."
  def owners, do: Enum.map(config()[:owners] || [], &String.downcase/1)

  def owner?(owner) when is_binary(owner), do: String.downcase(owner) in owners()

  @doc "GitHub's web origin (authorize, settings), without a trailing slash."
  def web_url, do: String.trim_trailing(config()[:url] || "https://github.com", "/")

  @doc "The REST API base URL: `GITHUB_API_URL`, `api.github.com`, or `<GITHUB_URL>/api/v3`."
  def api_url do
    cond do
      present?(config()[:api_url]) -> String.trim_trailing(config()[:api_url], "/")
      present?(config()[:url]) -> web_url() <> "/api/v3"
      true -> "https://api.github.com"
    end
  end

  def client_id, do: config()[:client_id]

  @doc """
  The person's page for Switchboard's OAuth App on GitHub, where they request an organization's
  approval (or see that it is pending).
  """
  def app_settings_url, do: web_url() <> "/settings/connections/applications/#{client_id()}"

  defp present?(s), do: is_binary(s) and s != ""

  ## Requests

  @doc """
  GET `path` (under the API base URL) as the scope's user. `{:ok, body}` or a reason:
  `:not_connected`, `:rejected`, `:unauthorized`, `:forbidden`, `:not_found`,
  `{:rate_limited, seconds}`, `{:sso, url}`, `:not_configured`, `{:status, n}`...
  """
  def get(scope, path, params \\ []) do
    with {:ok, token} <- token(scope),
         :ok <- not_limited(token) do
      case raw_get(token, path, params) do
        # A renamed or transferred repository answers 301 to its new API URL: follow it once.
        {:redirect, location} ->
          case api_path(location) do
            {:ok, moved, query} -> raw_get(token, moved, query) |> no_redirect()
            :error -> {:error, :unexpected_response}
          end

        other ->
          other
      end
    end
  end

  defp no_redirect({:redirect, _}), do: {:error, :unexpected_response}
  defp no_redirect(other), do: other

  # A location on the API host, as a path under the API base URL and its query.
  defp api_path(location) do
    api = URI.parse(api_url())
    uri = URI.parse(location)
    base = api.path || ""

    if uri.scheme == api.scheme and uri.host == api.host and uri.port == api.port and
         String.starts_with?(uri.path || "", base) do
      {:ok, String.replace_prefix(uri.path, base, ""),
       URI.decode_query(uri.query || "") |> Map.to_list()}
    else
      :error
    end
  end

  defp token(scope) do
    if configured?() do
      case Upstreams.credential(scope, :github) do
        {:ok, %{"access_token" => token}} when is_binary(token) -> {:ok, token}
        {:ok, _} -> {:error, :rejected}
        error -> error
      end
    else
      {:error, :not_configured}
    end
  end

  defp raw_get(token, path, params) do
    key = {:github_etag, hash(token), path, params}

    cached =
      case Cache.peek(key) do
        {:ok, {etag, body}} -> {etag, body}
        :error -> nil
      end

    headers =
      [{"x-github-api-version", @api_version}] ++
        if(cached, do: [{"if-none-match", elem(cached, 0)}], else: [])

    Upstreams.request(:github,
      method: :get,
      url: path,
      params: params,
      auth: {:bearer, token},
      headers: headers
    )
    |> handle(token, key, cached)
  end

  defp handle({:ok, %Req.Response{status: 304}}, _token, _key, {_etag, body}), do: {:ok, body}

  defp handle({:ok, %Req.Response{status: status} = resp}, _token, key, _cached)
       when status in 200..299 do
    case Req.Response.get_header(resp, "etag") do
      [etag | _] -> Cache.put(key, {etag, resp.body}, @etag_ttl)
      [] -> :ok
    end

    {:ok, resp.body}
  end

  defp handle({:ok, %Req.Response{status: status} = resp}, _token, _key, _cached)
       when status in [301, 302, 303, 307, 308] do
    case Req.Response.get_header(resp, "location") do
      [location | _] -> {:redirect, location}
      [] -> {:error, :unexpected_response}
    end
  end

  defp handle({:ok, %Req.Response{status: status} = resp}, token, _key, _cached)
       when status in [403, 429] do
    cond do
      seconds = limited_for(resp) ->
        until = System.monotonic_time(:millisecond) + seconds * 1000
        Cache.put({:github_limited, hash(token)}, until, seconds * 1000)
        {:error, {:rate_limited, seconds}}

      url = sso_url(resp) ->
        {:error, {:sso, url}}

      status == 429 ->
        {:error, {:rate_limited, 60}}

      true ->
        {:error, :forbidden}
    end
  end

  defp handle(result, _token, _key, _cached), do: Upstreams.body(result)

  # Seconds until the token's budget resets, when this answer says it is used up.
  defp limited_for(resp) do
    header = fn name -> resp |> Req.Response.get_header(name) |> List.first() end

    cond do
      (retry = header.("retry-after")) && match?({_, ""}, Integer.parse(retry)) ->
        retry |> String.to_integer() |> clamp()

      header.("x-ratelimit-remaining") == "0" ->
        case Integer.parse(header.("x-ratelimit-reset") || "") do
          {reset, ""} -> clamp(reset - System.os_time(:second))
          _ -> 60
        end

      true ->
        nil
    end
  end

  defp clamp(seconds), do: seconds |> max(1) |> min(3600)

  # `X-GitHub-SSO: required; url=https://github.com/orgs/<org>/sso?authorization_request=...`
  defp sso_url(resp) do
    with [value | _] <- Req.Response.get_header(resp, "x-github-sso"),
         [_, url] <- Regex.run(~r/url=(\S+)/, value),
         %URI{host: host} when is_binary(host) <- URI.parse(url),
         true <- host == URI.parse(web_url()).host do
      url
    else
      _ -> if Req.Response.get_header(resp, "x-github-sso") != [], do: app_settings_url()
    end
  end

  defp not_limited(token) do
    case Cache.peek({:github_limited, hash(token)}) do
      {:ok, until} ->
        left = div(until - System.monotonic_time(:millisecond), 1000)
        {:error, {:rate_limited, clamp(left)}}

      :error ->
        :ok
    end
  end

  defp hash(token), do: :crypto.hash(:sha256, token)

  ## Repositories and pull requests (Forgejo's names and shapes)

  def repo(scope, owner, name), do: get(scope, "/repos/#{owner}/#{name}")

  @doc """
  Pull request search, with `Switchboard.Forgejo.search_prs/2`'s parameters: `q`, `state`
  (`open`, `closed`, `all`), `created`, `review_requested`, `reviewed`, `assigned`, `owner`,
  `repo` (`owner/name`), `since` (ISO 8601), `limit`. Without `owner` or `repo` it searches the
  configured owners only (`GITHUB_OWNERS`).
  """
  def search_prs(scope, params) do
    query = search_query(params)

    with {:ok, %{"items" => items}} <-
           get(scope, "/search/issues",
             q: query,
             sort: "updated",
             order: "desc",
             per_page: min(params[:limit] || 20, 50)
           ) do
      {:ok, Enum.map(items, &normalize_issue/1)}
    else
      {:ok, _} -> {:error, :unexpected_response}
      error -> error
    end
  end

  @doc false
  def search_query(params) do
    where =
      cond do
        repo = params[:repo] -> ["repo:#{repo}"]
        owner = params[:owner] -> ["user:#{owner}"]
        true -> Enum.map(owners(), &"user:#{&1}")
      end

    [
      "is:pr",
      case params[:state] do
        "closed" -> "is:closed"
        "all" -> nil
        _ -> "is:open"
      end,
      params[:created] && "author:@me",
      params[:review_requested] && "review-requested:@me",
      params[:reviewed] && "reviewed-by:@me",
      params[:assigned] && "assignee:@me",
      params[:since] && "updated:>=#{since(params[:since])}",
      present?(params[:q]) && params[:q]
    ]
    |> Enum.filter(& &1)
    |> Kernel.++(where)
    |> Enum.join(" ")
  end

  defp since(value) do
    case DateTime.from_iso8601(to_string(value)) do
      {:ok, dt, _} -> dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      _ -> value
    end
  end

  def pull(scope, owner, repo, number) do
    with {:ok, pr} <- get(scope, "/repos/#{owner}/#{repo}/pulls/#{number}") do
      teams =
        for t <- pr["requested_teams"] || [], do: %{"login" => "#{owner}/#{t["slug"]} (team)"}

      {:ok,
       pr
       |> Map.put("host", "github")
       |> Map.put("requested_reviewers", (pr["requested_reviewers"] || []) ++ teams)}
    end
  end

  @doc "Reviews, with Forgejo's states (`REQUEST_CHANGES`, `COMMENT`) and `dismissed`."
  def reviews(scope, owner, repo, number) do
    with {:ok, list} <-
           get(scope, "/repos/#{owner}/#{repo}/pulls/#{number}/reviews", per_page: 100) do
      {:ok,
       Enum.map(list, fn r ->
         state =
           case r["state"] do
             "CHANGES_REQUESTED" -> "REQUEST_CHANGES"
             "COMMENTED" -> "COMMENT"
             other -> other
           end

         Map.merge(r, %{"state" => state, "dismissed" => r["state"] == "DISMISSED"})
       end)}
    end
  end

  def pull_commits(scope, owner, repo, number),
    do: get(scope, "/repos/#{owner}/#{repo}/pulls/#{number}/commits", per_page: 100)

  @doc """
  CI for a commit, as Forgejo's combined status: check runs (GitHub Actions jobs and other
  apps) and legacy commit statuses in one `statuses` list, with an overall `state`.
  """
  def status(scope, owner, repo, ref) do
    with {:ok, %{"check_runs" => runs}} <-
           get(scope, "/repos/#{owner}/#{repo}/commits/#{ref}/check-runs", per_page: 100) do
      legacy =
        case get(scope, "/repos/#{owner}/#{repo}/commits/#{ref}/status", per_page: 100) do
          {:ok, %{"statuses" => list}} when is_list(list) -> list
          _ -> []
        end

      statuses =
        Enum.map(runs, fn r ->
          %{
            "context" => r["name"],
            "status" => check_state(r),
            "description" => get_in(r, ["output", "title"]) || r["conclusion"] || r["status"],
            "target_url" => r["html_url"]
          }
        end) ++
          Enum.map(legacy, fn s ->
            %{
              "context" => s["context"],
              "status" => s["state"],
              "description" => s["description"],
              "target_url" => s["target_url"]
            }
          end)

      {:ok, %{"state" => overall(statuses), "statuses" => statuses, "host" => "github"}}
    else
      {:ok, _} -> {:error, :unexpected_response}
      error -> error
    end
  end

  defp check_state(%{"status" => "completed", "conclusion" => c}) do
    case c do
      c when c in ["success", "neutral"] -> "success"
      "skipped" -> "skipped"
      "cancelled" -> "cancelled"
      _ -> "failure"
    end
  end

  defp check_state(%{"status" => "in_progress"}), do: "running"
  defp check_state(_), do: "pending"

  defp overall([]), do: "pending"

  defp overall(statuses) do
    states = Enum.map(statuses, & &1["status"])

    cond do
      Enum.any?(states, &(&1 in ["failure", "error", "cancelled"])) -> "failure"
      Enum.any?(states, &(&1 in ["pending", "running", "waiting"])) -> "pending"
      true -> "success"
    end
  end

  @doc "A branch, with its head commit as `commit.id` (Forgejo's shape)."
  def branch(scope, owner, repo, branch) do
    path =
      branch
      |> String.split("/")
      |> Enum.map_join("/", fn seg -> URI.encode(seg, &URI.char_unreserved?/1) end)

    with {:ok, b} <- get(scope, "/repos/#{owner}/#{repo}/branches/#{path}") do
      {:ok, Map.put(b, "commit", %{"id" => get_in(b, ["commit", "sha"])})}
    end
  end

  ## Actions

  @doc """
  Workflow runs as `%{"workflow_runs" => [...]}`, with Forgejo's parameters: `head_sha`,
  `limit`, and `run_number` (on GitHub, the run id from the run URL).
  """
  def runs(scope, owner, repo, params) do
    case params[:run_number] do
      id when is_integer(id) ->
        case run(scope, owner, repo, id) do
          {:ok, run} -> {:ok, %{"workflow_runs" => [run]}}
          {:error, :not_found} -> {:ok, %{"workflow_runs" => []}}
          error -> error
        end

      _ ->
        query =
          [per_page: params[:limit] || 10] ++
            if(sha = params[:head_sha], do: [head_sha: sha], else: [])

        with {:ok, %{"workflow_runs" => runs}} <-
               get(scope, "/repos/#{owner}/#{repo}/actions/runs", query) do
          {:ok, %{"workflow_runs" => Enum.map(runs, &normalize_run/1)}}
        else
          {:ok, _} -> {:error, :unexpected_response}
          error -> error
        end
    end
  end

  def run(scope, owner, repo, id) do
    with {:ok, run} <- get(scope, "/repos/#{owner}/#{repo}/actions/runs/#{id}"),
         do: {:ok, normalize_run(run)}
  end

  @doc "The jobs of a run's latest attempt, each with `failed_step` (from the job's steps)."
  def jobs(scope, owner, repo, run_id) do
    with {:ok, %{"jobs" => jobs}} <-
           get(scope, "/repos/#{owner}/#{repo}/actions/runs/#{run_id}/jobs",
             filter: "latest",
             per_page: 50
           ) do
      {:ok,
       Enum.map(jobs, fn job ->
         failed = Enum.find(job["steps"] || [], &(&1["conclusion"] == "failure"))

         %{
           "id" => job["id"],
           "name" => job["name"],
           "status" => run_status(job),
           "html_url" => job["html_url"],
           "failed_step" => failed && failed["name"],
           "host" => "github"
         }
       end)}
    else
      {:ok, _} -> {:error, :unexpected_response}
      error -> error
    end
  end

  @doc """
  A job's plaintext log. GitHub answers with a redirect to a short-lived download URL; that one is
  fetched without the token (only http(s), no credentials in it, capped at 4 MB).
  """
  def job_log(scope, owner, repo, job_id) do
    with {:ok, token} <- token(scope),
         :ok <- not_limited(token) do
      case raw_get(token, "/repos/#{owner}/#{repo}/actions/jobs/#{job_id}/logs", []) do
        {:redirect, location} -> download(location)
        {:ok, body} when is_binary(body) -> {:ok, body}
        {:ok, _} -> {:error, :unexpected_response}
        error -> error
      end
    end
  end

  defp download(location) do
    case URI.parse(location) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["https", "http"] and is_binary(host) and host != "" ->
        if scheme == "https" or URI.parse(api_url()).scheme == "http" do
          Upstreams.request(:github, url: location, max_body: @max_log)
          |> Upstreams.body()
          |> case do
            {:ok, body} when is_binary(body) -> {:ok, body}
            {:ok, _} -> {:error, :unexpected_response}
            error -> error
          end
        else
          {:error, :unexpected_response}
        end

      _ ->
        {:error, :unexpected_response}
    end
  end

  @doc """
  The failed step and the tail of a GitHub Actions job log, like `Forgejo.failure_tail/2`:
  timestamps dropped, `##[group]`/`##[endgroup]` markers removed, secrets scrubbed. The step
  starts at the last `##[group]Run …` line before the failure, and the tail ends at
  `##[error]Process completed with exit code N.` (earlier `##[error]` lines are kept). `step` is
  the command of that `Run` line; prefer the job's `failed_step` name when there is one.
  """
  def failure_tail(log, lines \\ 60) do
    rows =
      log
      |> String.replace_prefix("\uFEFF", "")
      |> String.split(~r/\r?\n/)
      |> Enum.map(&String.replace(&1, ~r/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z\s?/, ""))

    fail_at =
      Enum.find_index(rows, &(&1 =~ ~r/^##\[error\]Process completed with exit code/)) ||
        case Enum.find_index(rows, &String.starts_with?(&1, "##[error]")) do
          nil -> length(rows)
          i -> i + 1
        end

    before = Enum.take(rows, fail_at)

    {step, step_at} =
      before
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value({nil, 0}, fn {row, i} ->
        case Regex.run(~r/^##\[group\]Run (.+)$/u, row) do
          [_, command] -> {String.trim(command), i + 1}
          _ -> nil
        end
      end)

    tail =
      before
      |> Enum.drop(step_at)
      |> Enum.reject(&(&1 =~ ~r/^##\[(end)?group\]/))
      |> Enum.take(-lines)
      |> Enum.join("\n")
      |> Forgejo.scrub()

    %{step: step, tail: tail}
  end

  ## Normalizing

  defp normalize_issue(item) do
    full_name =
      case URI.parse(item["repository_url"] || "") do
        %URI{path: path} when is_binary(path) ->
          path |> String.split("/", trim: true) |> Enum.take(-2) |> Enum.join("/")

        _ ->
          nil
      end

    merged_at = get_in(item, ["pull_request", "merged_at"])

    item
    |> Map.take(
      ~w(id number title body state html_url user updated_at created_at closed_at draft)
    )
    |> Map.merge(%{
      "repository" => %{"full_name" => full_name},
      "pull_request" => %{"merged" => merged_at != nil, "merged_at" => merged_at},
      "host" => "github"
    })
  end

  defp normalize_run(r) do
    workflow =
      case r["path"] do
        path when is_binary(path) and path != "" -> Path.basename(path)
        _ -> r["name"]
      end

    %{
      "id" => r["id"],
      "index_in_repo" => r["id"],
      "run_number" => r["run_number"],
      "status" => run_status(r),
      "title" => r["display_title"] || r["name"],
      "workflow_id" => workflow,
      "event" => r["event"],
      "commit_sha" => r["head_sha"],
      "html_url" => r["html_url"],
      "started" => r["run_started_at"] || r["created_at"],
      "host" => "github"
    }
  end

  @doc false
  # One status for a run or job, as Forgejo reports it.
  def run_status(%{"status" => "completed", "conclusion" => conclusion}) do
    case conclusion do
      c when c in ["success", "neutral"] -> "success"
      "skipped" -> "skipped"
      "cancelled" -> "cancelled"
      _ -> "failure"
    end
  end

  def run_status(%{"status" => "in_progress"}), do: "running"
  def run_status(_), do: "waiting"
end
