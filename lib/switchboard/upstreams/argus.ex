defmodule Switchboard.Upstreams.Argus do
  @moduledoc """
  Argus: a personal `argus_...` token, sent as a bearer token. It sees the
  projects of the person's teams (admins see every project). The test reads `GET /api/v1/me`
  and matches the token's owner to the person by email.
  """
  @behaviour Switchboard.Upstream
  use Gettext, backend: SwitchboardWeb.Gettext

  alias Switchboard.Upstreams

  @impl true
  def system, do: "argus"
  @impl true
  def label, do: "Argus"
  # The API tokens section of the account settings page.
  @impl true
  def key_url, do: Upstreams.base_url(:argus) <> "/settings#api-tokens"

  @impl true
  def permissions,
    do: gettext("A personal API token (starts with argus_). It sees your teams' projects.")

  @impl true
  def fields, do: [%{name: "token", label: gettext("API token"), secret?: true}]

  @impl true
  def whoami(%{"token" => "argus_" <> _} = cred) do
    case Switchboard.Argus.me(cred) do
      {:ok, me} ->
        {:ok,
         %{
           "username" => nil,
           "email" => me["email"],
           "name" => me["name"],
           "role" => me["role"],
           "teams" => me["teams"]
         }}

      error ->
        error
    end
  end

  def whoami(_), do: {:error, :invalid_format}
end
