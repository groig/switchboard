defmodule Switchboard.Releases.Fake do
  @moduledoc """
  Synthetic releases for development (the real feed is usually internal-only). Same shape as the real
  feed; nothing here is real data. Task ids use the `DEMO` project.
  """
  @behaviour Switchboard.Releases

  @impl true
  def list(params) do
    now = DateTime.utc_now(:second)
    since = params[:since] && elem(DateTime.from_iso8601(params[:since]), 1)

    releases =
      samples(now)
      |> Enum.filter(&(is_nil(params[:repo]) or &1["repo"] == params[:repo]))
      |> Enum.filter(fn r ->
        is_nil(since) or DateTime.compare(parse(r["startedAt"]), since) != :lt
      end)
      |> Enum.take(params[:limit] || 50)

    {:ok, releases}
  end

  defp parse(s), do: s |> DateTime.from_iso8601() |> elem(1)

  @doc false
  def samples(now) do
    at = fn hours -> now |> DateTime.add(-round(hours * 3600)) |> DateTime.to_iso8601() end
    sha = fn seed -> :crypto.hash(:sha, seed) |> Base.encode16(case: :lower) end

    [
      %{
        "repo" => "demo",
        "name" => "release-demo.3",
        "sha" => sha.("r3"),
        "status" => "success",
        "startedAt" => at.(5),
        "finishedAt" => at.(4.9),
        "actor" => "dev",
        "runUrl" => "https://git.example.com/demo/demo/actions/runs/3",
        "cardUrl" => "https://chat.example.com/channel/demo?msg=3",
        "previous" => "release-demo.2",
        "commitCount" => 2,
        "migrations" => 0,
        "authors" => ["dev"],
        "commits" => [sha.("c3a"), sha.("c3b")],
        "highlights" => ["Invoices can be exported as CSV (DEMO-12)"],
        "tasks" => [
          %{
            "id" => "DEMO-12",
            "url" => "https://plane.example.com/demo/browse/DEMO-12/",
            "match" => "mentioned",
            "commits" => [sha.("c3a")],
            "evidence" => nil
          }
        ],
        "health" => "yellow",
        "watching" => true,
        "argusIssues" => [
          %{
            "id" => "7",
            "title" => "KeyError: 'currency'",
            "url" => "https://bugs.example.com/demo/issues/7",
            "triageUrl" => "https://chat.example.com/channel/demo?msg=7",
            "fromRelease" => false
          }
        ]
      },
      %{
        "repo" => "demo",
        "name" => "release-demo.2",
        "sha" => sha.("r2"),
        "status" => "failure",
        "startedAt" => at.(30),
        "finishedAt" => at.(29.8),
        "actor" => "dev",
        "runUrl" => "https://git.example.com/demo/demo/actions/runs/2",
        "cardUrl" => "https://chat.example.com/channel/demo?msg=2",
        "previous" => "release-demo.1",
        "commitCount" => 1,
        "migrations" => 1,
        "authors" => ["dev"],
        "commits" => [sha.("c2a")],
        "highlights" => [],
        "tasks" => [],
        "health" => nil,
        "watching" => false,
        "argusIssues" => []
      }
    ]
  end
end
