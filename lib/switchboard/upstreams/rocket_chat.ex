defmodule Switchboard.Upstreams.RocketChat do
  @moduledoc """
  Rocket.Chat (8.x): a personal access token plus the user id, sent as
  `X-Auth-Token` and `X-User-Id`. Used only for messages the person approves.
  """
  @behaviour Switchboard.Upstream
  use Gettext, backend: SwitchboardWeb.Gettext

  alias Switchboard.Upstreams

  @impl true
  def system, do: "rocketchat"
  @impl true
  def label, do: "Rocket.Chat"
  @impl true
  def key_url, do: Upstreams.base_url(:rocketchat) <> "/account/tokens"

  @impl true
  def permissions,
    do:
      gettext(
        "A personal access token (tick \"Ignore Two Factor Authentication\") and your user id, both shown once when you create it."
      )

  @impl true
  def fields do
    [
      %{name: "user_id", label: gettext("User id"), secret?: false},
      %{name: "token", label: gettext("Access token"), secret?: true}
    ]
  end

  @impl true
  def whoami(%{"token" => token, "user_id" => user_id}) do
    with {:ok, %{body: %{"username" => username} = me}} <-
           Upstreams.request(:rocketchat,
             url: "/api/v1/me",
             headers: [{"x-auth-token", token}, {"x-user-id", user_id}]
           )
           |> Upstreams.classify() do
      email =
        case me["emails"] do
          [%{"address" => address} | _] -> address
          _ -> nil
        end

      {:ok, %{"username" => username, "email" => email, "name" => me["name"]}}
    else
      {:ok, _} -> {:error, :unexpected_response}
      error -> error
    end
  end

  def whoami(_), do: {:error, :unauthorized}
end
