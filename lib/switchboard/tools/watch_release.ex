defmodule Switchboard.Tools.WatchRelease do
  @moduledoc "Watch the next production release of a repo; optionally its 24 h health too."
  use Switchboard.Tools.Support

  alias Switchboard.Releases
  alias Switchboard.Tools.WatchSupport
  alias Switchboard.Watches.ReleaseCheck

  @impl true
  def name, do: "watch_release"
  @impl true
  def title, do: "Watch the next release"
  @impl true
  def description,
    do:
      "Use when the user wants to be told when the next production release of a repo " <>
        "finishes (success, failure or cancelled), from the release cards' feed. With health, a " <>
        "second DM when its 24 h watch window ends (green/yellow/red and the errors it " <>
        "introduced). Only notifies the user who asked, so their request is the confirmation."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "repo" => %{
          "type" => "string",
          "description" => "Repository name as in the release cards, e.g. web."
        },
        "health" => %{
          "type" => "boolean",
          "description" => "Also DM the 24 h health of a successful release (default false)."
        },
        "hours" => WatchSupport.hours_schema()
      },
      "required" => ["repo"]
    }
  end

  @impl true
  def annotations,
    do: %{read_only: false, destructive: false, idempotent: false, open_world: true}

  @impl true
  def connections, do: []

  @impl true
  def aliases, do: %{"repository" => "repo"}

  @impl true
  def example do
    %{
      args: %{"repo" => "demo", "health" => true},
      output:
        "Watching demo: Switchboard will DM you in Rocket.Chat (as @ana) when its next " <>
          "production release finishes, and again with its health after 24 h. Expires " <>
          "2026-11-27 10:00 (Europe/Madrid). Watch id: `5b1c…` (list_watches, cancel_watch, or " <>
          "https://switchboard.example.com/watches)."
    }
  end

  @impl true
  def call(scope, %{"repo" => repo} = args) do
    repo = String.trim(repo)
    health? = args["health"] == true

    with true <-
           repo =~ ~r/^[\w.\-\/]{1,120}$/ ||
             {:error, "repo must be a release repo name, e.g. web"},
         {:ok, hours} <- WatchSupport.hours(args),
         {:ok, username} <- WatchSupport.recipient(scope),
         {:ok, releases} <- Releases.list(limit: 200) |> feed_error(),
         {:ok, repo} <- known(releases, repo, scope) do
      WatchSupport.create(
        scope,
        %{
          kind: "release",
          target: %{"repo" => repo},
          subject: repo,
          options: %{"health" => health?},
          hours: hours,
          state: %{"baseline" => ReleaseCheck.baseline(releases, repo)}
        },
        username,
        "when its next production release finishes" <>
          if(health?, do: ", and again with its health after 24 h", else: "")
      )
    end
  end

  defp feed_error({:error, reason}), do: {:error, problem(:releases, reason)}
  defp feed_error(ok), do: ok

  defp known(releases, repo, scope) do
    case Releases.resolve_repo(releases, repo) do
      {:ok, repo} ->
        {:ok, repo}

      {:ambiguous, repos} ->
        {:error,
         "\"#{cell(repo)}\" matches several repos with releases: " <>
           Enum.map_join(repos, ", ", &"`#{&1}`") <> ". Call again with one of them."}

      :unknown ->
        {:error,
         "No release of `#{cell(repo)}` in the last 90 days.\n\n" <>
           Switchboard.Tools.ReleaseRender.feed_hint(releases, scope)}
    end
  end
end
