defmodule Switchboard.Tools.Whoami do
  @moduledoc "Who the caller is, as Switchboard sees them, and which systems they connected."
  @behaviour Switchboard.Tool

  alias Switchboard.{Connections, OAuth, Scope, Upstreams}

  @impl true
  def name, do: "whoami"
  @impl true
  def title, do: "Who am I"
  @impl true
  def description,
    do:
      "Shows who you are signed in as in Switchboard, through which client, and which systems " <>
        "(Forgejo, Plane, Argus, Outline, Rocket.Chat) you have connected. Use it when a tool " <>
        "says a system isn't connected."

  @impl true
  def input_schema, do: %{"type" => "object", "properties" => %{}}
  @impl true
  def annotations, do: %{read_only: true, open_world: false}
  @impl true
  def connections, do: []

  @impl true
  def example do
    %{
      args: %{},
      output: """
      ## You

      | | |
      |---|---|
      | Forgejo user | `ana` |
      | Name | Ana García |
      | Email | ana@example.com |
      | Admin | no |
      | Client | Claude Code |
      | Language | es |

      ## Connections

      | System | Status |
      |---|---|
      | Forgejo | connected |
      | Plane | connected |
      | Argus | not connected |
      | Outline | connected |
      | Rocket.Chat | not connected |

      Connect the missing ones at https://switchboard.example.com/connections
      """
    }
  end

  @impl true
  def call(%Scope{user: user} = scope, _args) do
    client = scope.client_name || scope.client_id || "personal token"
    connections = Connections.list(scope)

    rows =
      Enum.map_join(Upstreams.all(), "\n", fn mod ->
        "| #{mod.label()} | #{status(connections[mod.system()])} |"
      end)

    missing? =
      Enum.any?(Upstreams.all(), &(status(connections[&1.system()]) != "connected"))

    {:ok,
     """
     ## You

     | | |
     |---|---|
     | Forgejo user | `#{user.username}` |
     | Name | #{user.name || "-"} |
     | Email | #{user.email || "-"} |
     | Admin | #{if user.admin, do: "yes", else: "no"} |
     | Client | #{client} |
     | Language | #{user.locale} |

     ## Connections

     | System | Status |
     |---|---|
     #{rows}
     #{if missing?, do: "\nConnect the missing ones at #{OAuth.issuer()}/connections\n", else: ""}\
     """}
  end

  defp status(nil), do: "not connected"
  defp status(%{status: "ok"}), do: "connected"
  defp status(%{status: "rejected"}), do: "key rejected; link it again"
  defp status(%{status: _}), do: "connected (not tested)"
end
