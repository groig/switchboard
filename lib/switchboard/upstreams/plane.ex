defmodule Switchboard.Upstreams.Plane do
  @moduledoc "Plane (v1.4): a personal API key, sent as `X-API-Key`."
  @behaviour Switchboard.Upstream
  use Gettext, backend: SwitchboardWeb.Gettext

  alias Switchboard.Upstreams

  @impl true
  def system, do: "plane"
  @impl true
  def label, do: "Plane"

  @impl true
  def key_url do
    workspace = Upstreams.config(:plane)[:workspace]
    Upstreams.base_url(:plane) <> "/#{workspace}/settings/account/api-tokens"
  end

  @impl true
  def permissions,
    do: gettext("A personal access token. It acts as you, with your own workspace role.")

  @impl true
  def fields, do: [%{name: "token", label: gettext("API key"), secret?: true}]

  @impl true
  def whoami(%{"token" => token}) do
    with {:ok, %{body: %{} = me}} <-
           Upstreams.request(:plane, url: "/api/v1/users/me/", headers: [{"x-api-key", token}])
           |> Upstreams.classify() do
      {:ok,
       %{
         "username" => me["display_name"],
         "email" => me["email"],
         "name" =>
           [me["first_name"], me["last_name"]]
           |> Enum.reject(&(&1 in [nil, ""]))
           |> Enum.join(" ")
       }}
    else
      {:ok, _} -> {:error, :unexpected_response}
      error -> error
    end
  end
end
