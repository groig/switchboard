defmodule Switchboard.Upstreams.Outline do
  @moduledoc "Outline (1.x): a personal API key, sent as a bearer token."
  @behaviour Switchboard.Upstream
  use Gettext, backend: SwitchboardWeb.Gettext

  alias Switchboard.Upstreams

  @impl true
  def system, do: "outline"
  @impl true
  def label, do: "Outline"
  # Outline 1.7+ ("API & Access"); 0.84 to 1.6 called it /settings/api-and-apps.
  @impl true
  def key_url, do: Upstreams.base_url(:outline) <> "/settings/api-and-access"

  @impl true
  def permissions,
    do:
      gettext(
        "A personal API key. Read and write documents; Switchboard only creates drafts, never publishes."
      )

  @impl true
  def fields, do: [%{name: "token", label: gettext("API key"), secret?: true}]

  @impl true
  def whoami(%{"token" => token}) do
    with {:ok, %{body: %{"data" => %{"user" => user}}}} <-
           Upstreams.request(:outline,
             method: :post,
             url: "/api/auth.info",
             auth: {:bearer, token},
             json: %{}
           )
           |> Upstreams.classify() do
      {:ok, %{"username" => nil, "email" => user["email"], "name" => user["name"]}}
    else
      {:ok, _} -> {:error, :unexpected_response}
      error -> error
    end
  end
end
