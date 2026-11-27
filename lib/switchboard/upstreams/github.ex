defmodule Switchboard.Upstreams.GitHub do
  @moduledoc """
  GitHub: an OAuth token from Switchboard's OAuth App, linked in the browser (Connect GitHub on
  the Connections page) and revoked on disconnect. Only for repositories that live on GitHub
  (`GITHUB_OWNERS`, or `github:owner/repo`); hidden when the app isn't configured.
  """
  @behaviour Switchboard.Upstream
  use Gettext, backend: SwitchboardWeb.Gettext

  alias Switchboard.GitHub
  alias Switchboard.GitHub.Login

  @impl true
  def system, do: "github"
  @impl true
  def label, do: "GitHub"
  @impl true
  def key_url, do: nil

  @impl true
  def permissions,
    do:
      gettext(
        "Connect in your browser. Switchboard only reads pull requests, checks and Actions logs, though GitHub grants it the repo scope."
      )

  @impl true
  def fields, do: []

  @impl true
  def enabled?, do: GitHub.configured?()

  @impl true
  def connect_path, do: "/auth/github"

  @impl true
  def optional?, do: true

  @impl true
  def whoami(%{"access_token" => token}) when is_binary(token), do: Login.identity(token)
  def whoami(_), do: {:error, :unauthorized}
end
