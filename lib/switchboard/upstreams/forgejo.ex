defmodule Switchboard.Upstreams.Forgejo do
  @moduledoc """
  Forgejo: the OAuth token from sign-in, stored encrypted and refreshed by
  `Switchboard.Connections.forgejo_token/1`. Nothing to paste.
  """
  @behaviour Switchboard.Upstream
  use Gettext, backend: SwitchboardWeb.Gettext

  alias Switchboard.Forgejo.Login

  @impl true
  def system, do: "forgejo"
  @impl true
  def label, do: "Forgejo"
  @impl true
  def key_url, do: nil

  @impl true
  def permissions,
    do: gettext("Linked automatically when you sign in. Switchboard acts as you.")

  @impl true
  def fields, do: []

  @impl true
  def whoami(%{"access_token" => token}) do
    case Login.fetch_profile(token) do
      {:ok, %{identity: id}} ->
        {:ok, %{"username" => id.username, "email" => id.email, "name" => id.name}}

      {:error, :unauthorized} ->
        {:error, :unauthorized}

      {:error, _} ->
        {:error, :unavailable}
    end
  end
end
