defmodule Switchboard.Repos do
  @moduledoc """
  Where a repository lives, Forgejo or GitHub, and the client for it.

  `resolve/2` accepts:

    * `owner/repo`: GitHub when `owner` is one of `GITHUB_OWNERS` (and GitHub is configured),
      Forgejo otherwise;
    * a URL of either server (repository, pull request or Actions run), routed by host; the PR or
      run number in it is kept;
    * an explicit `github:owner/repo` or `forgejo:owner/repo`.

  `Switchboard.Forgejo` and `Switchboard.GitHub` have the same read functions with the same
  shapes, so tools call `client(ref)` and render one way. Both only send GET.

  The joins (`search_all/2`) add GitHub for people who connected it, limited to the configured
  owners; a failing system becomes a note, never a failed answer.
  """

  alias Switchboard.{Connections, Forgejo, GitHub, Scope, Upstreams}
  alias Switchboard.Repos.Ref

  @usage "repo must be owner/name, a repository URL, or github:owner/name / forgejo:owner/name"

  @doc "The sentence tools put in their `repo` argument's schema description."
  def schema_description do
    "Repository: owner/name (GitHub when the owner is one of the organizations the admin " <>
      "configured as on GitHub, Forgejo otherwise), a repository, pull request or run URL, or " <>
      "an explicit github:owner/name or forgejo:owner/name."
  end

  @doc """
  Resolves a `repo` argument to a `%Ref{}`, or `{:error, line}`. With `default: :forgejo`, a
  bare `owner/repo` is Forgejo regardless of `GITHUB_OWNERS` (for stored watch targets, which
  carry `github:` when they are on GitHub).
  """
  def resolve(input, opts \\ [])

  def resolve(input, opts) when is_binary(input) do
    s = String.trim(input)

    cond do
      s == "" -> {:error, @usage}
      prefixed?(s, "github:") -> by_name(:github, drop_prefix(s))
      prefixed?(s, "forgejo:") -> by_name(:forgejo, drop_prefix(s))
      s =~ ~r{^https?://}i -> from_url(s)
      true -> routed(s, opts)
    end
  end

  def resolve(_input, _opts), do: {:error, @usage}

  def usage, do: @usage

  defp prefixed?(s, prefix), do: String.starts_with?(String.downcase(s), prefix)
  defp drop_prefix(s), do: s |> String.split(":", parts: 2) |> List.last() |> String.trim()

  defp by_name(host, s) do
    with {:ok, owner, name} <- parse(s), do: check(%Ref{host: host, owner: owner, name: name})
  end

  defp routed(s, opts) do
    with {:ok, owner, name} <- parse(s) do
      host =
        if opts[:default] != :forgejo and GitHub.configured?() and GitHub.owner?(owner),
          do: :github,
          else: :forgejo

      {:ok, %Ref{host: host, owner: owner, name: name}}
    end
  end

  defp parse(s) do
    case Forgejo.parse_repo(String.replace_suffix(s, ".git", "")) do
      {:ok, owner, name} -> {:ok, owner, name}
      {:error, :invalid_repo} -> {:error, @usage}
    end
  end

  defp check(%Ref{host: :github} = ref) do
    if GitHub.configured?(),
      do: {:ok, ref},
      else: {:error, Upstreams.problem(:github, :not_configured)}
  end

  defp check(ref), do: {:ok, ref}

  defp from_url(url) do
    uri = URI.parse(url)
    host = String.downcase(uri.host || "")
    forgejo = URI.parse(Forgejo.base_url())

    github_hosts =
      if GitHub.configured?(),
        do: [URI.parse(GitHub.web_url()).host, URI.parse(GitHub.api_url()).host],
        else: ["github.com", "api.github.com"]

    cond do
      host == String.downcase(forgejo.host || "") ->
        prefix = String.split(forgejo.path || "", "/", trim: true)

        segments(uri)
        |> drop_leading(prefix)
        |> drop_leading(["api", "v1", "repos"])
        |> from_segments(:forgejo, url)

      host in github_hosts ->
        segments(uri)
        |> drop_leading(["api", "v3"])
        |> drop_leading(["repos"])
        |> from_segments(:github, url)

      true ->
        {:error,
         "#{host} is neither this Switchboard's Forgejo (#{forgejo.host}) nor GitHub. " <> @usage}
    end
  end

  defp segments(%URI{path: path}), do: String.split(path || "", "/", trim: true)

  defp drop_leading(segments, prefix) do
    if Enum.take(segments, length(prefix)) == prefix,
      do: Enum.drop(segments, length(prefix)),
      else: segments
  end

  defp from_segments([owner, name | rest], host, _url) do
    with {:ok, owner, name} <- parse("#{owner}/#{name}"),
         {:ok, ref} <- check(%Ref{host: host, owner: owner, name: name}) do
      {:ok, %{ref | pr: number_after(rest, ["pull", "pulls"]), run: run_number(rest)}}
    end
  end

  defp from_segments(_segments, _host, url),
    do: {:error, "#{url} isn't a repository URL. " <> @usage}

  defp number_after([kind, n | _], kinds), do: if(kind in kinds, do: to_int(n))
  defp number_after(_, _), do: nil

  defp run_number(["actions", "runs", n | _]), do: to_int(n)
  defp run_number(_), do: nil

  defp to_int(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  @doc "The read client for a repository's host (`Switchboard.Forgejo` or `Switchboard.GitHub`)."
  def client(%Ref{host: :forgejo}), do: Forgejo
  def client(%Ref{host: :github}), do: GitHub

  @doc "The repository of a search hit or pull request map (GitHub's carry `\"host\" => \"github\"`)."
  def ref_for(item) do
    host = if item["host"] == "github", do: :github, else: :forgejo

    case Forgejo.parse_repo(get_in(item, ["repository", "full_name"]) || "") do
      {:ok, owner, name} -> {:ok, %Ref{host: host, owner: owner, name: name}}
      error -> error
    end
  end

  ## Messages

  @doc """
  The line for a failed read of a repository the person named. A Forgejo 404/400/422 says the
  repository isn't on Forgejo (and how to reach it on GitHub when GitHub is configured); a GitHub
  403/404 says the organization may need to approve Switchboard's app; a missing GitHub
  connection links the Connections row.
  """
  def problem(%Ref{host: :forgejo} = ref, reason) do
    if user_error?(reason) do
      "`#{Ref.full(ref)}` isn't on Forgejo, or you can't see it there." <> github_hint(ref)
    else
      Upstreams.problem(:forgejo, reason)
    end
  end

  def problem(%Ref{host: :github} = ref, reason) do
    case reason do
      :not_connected ->
        "`#{Ref.full(ref)}` is on GitHub, and your GitHub account isn't connected to " <>
          "Switchboard. Connect it at #{Upstreams.connection_url(:github)} (the `help` " <>
          "workflow shows every account and what is missing)."

      # Search answers 422 for a repository it can't see.
      r when r in [:not_found, :forbidden, {:status, 422}] ->
        "`#{Ref.full(ref)}` isn't visible to your GitHub account (or doesn't exist). If it " <>
          "is a private repository of an organization, an owner of `#{ref.owner}` may need to " <>
          "approve the Switchboard app: request it at #{GitHub.app_settings_url()}"

      other ->
        Upstreams.problem(:github, other)
    end
  end

  defp user_error?(:not_found), do: true
  defp user_error?({:status, s}) when s in [400, 404, 422], do: true
  defp user_error?(_), do: false

  defp github_hint(ref) do
    if GitHub.configured?(),
      do:
        " If it's on GitHub, use `github:#{Ref.full(ref)}`, or ask the admin to add " <>
          "`#{ref.owner}` to GITHUB_OWNERS.",
      else: ""
  end

  @doc """
  For a 404 on something inside a repository (a PR, run or branch): `line` when the repository
  itself is visible, otherwise why it isn't (`problem/2`).
  """
  def missing(scope, %Ref{} = ref, line) do
    case client(ref).repo(scope, ref.owner, ref.name) do
      {:ok, _} -> line
      {:error, reason} -> problem(ref, reason)
    end
  end

  ## Joins

  @doc """
  Whether the joins include GitHub for this person: GitHub is configured with owners, and they
  linked it (a rejected link still counts, so they see the note).
  """
  def github?(%Scope{user: user}) do
    GitHub.configured?() and GitHub.owners() != [] and
      Connections.get(user, "github") != nil
  end

  @doc "The systems a pull-request join reads, for `FanOut` entries and the audit row."
  def systems(%Scope{} = scope), do: if(github?(scope), do: [:forgejo, :github], else: :forgejo)

  @doc """
  Searches pull requests on Forgejo and, for people with GitHub, on GitHub (configured owners
  only), concurrently. `{:ok, items, notes}` when at least one answered (newest update first),
  `{:error, reason}` when Forgejo failed and GitHub isn't in play, `{:error, line}` when both
  failed.
  """
  def search_all(%Scope{} = scope, params) do
    github =
      if github?(scope),
        do: Task.async(fn -> GitHub.search_prs(scope, Keyword.delete(params, :owner)) end)

    forgejo = Forgejo.search_prs(scope, params)
    github = if github, do: Task.await(github, :infinity), else: :skip

    case {forgejo, github} do
      {{:ok, f}, :skip} ->
        {:ok, f, []}

      {{:ok, f}, {:ok, g}} ->
        {:ok, Enum.sort_by(f ++ g, &(&1["updated_at"] || ""), :desc), []}

      {{:ok, f}, {:error, reason}} ->
        {:ok, f, [Upstreams.problem(:github, reason)]}

      {{:error, reason}, :skip} ->
        {:error, reason}

      {{:error, reason}, {:ok, g}} ->
        {:ok, g, [Upstreams.problem(:forgejo, reason)]}

      {{:error, r1}, {:error, r2}} ->
        {:error, Upstreams.problem(:forgejo, r1) <> " " <> Upstreams.problem(:github, r2)}
    end
  end

  @doc "A stable key for a search hit across hosts (ids may repeat between Forgejo and GitHub)."
  def key(item), do: {item["host"] || "forgejo", item["id"]}
end
