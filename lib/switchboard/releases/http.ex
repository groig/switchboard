defmodule Switchboard.Releases.HTTP do
  @moduledoc """
  Reads the release bot's feed: `GET <RELEASES_URL>/releases?repo=&since=&limit=` with
  `Authorization: Bearer <RELEASES_TOKEN>`. The URL is usually internal (a container on a shared
  Docker network).
  """
  @behaviour Switchboard.Releases

  alias Switchboard.Upstreams

  @impl true
  def list(params) do
    config = Upstreams.config(:releases)

    case config[:token] do
      token when is_binary(token) and token != "" ->
        with {:ok, %{"releases" => releases}} when is_list(releases) <-
               Upstreams.request(:releases,
                 url: "/releases",
                 params: params,
                 auth: {:bearer, token}
               )
               |> Upstreams.body() do
          {:ok, releases}
        else
          {:ok, _} -> {:error, :unexpected_response}
          error -> error
        end

      _ ->
        {:error, :not_configured}
    end
  end
end
