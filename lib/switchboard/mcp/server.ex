defmodule Switchboard.MCP.Server do
  @moduledoc """
  The adapter between `anubis_mcp` and Switchboard's tools. **This is the only module that knows
  the MCP library**: it turns `Switchboard.Tool` modules into protocol tool definitions and
  dispatches `tools/call` to `Switchboard.Tools.run/3`. Swapping the library for our own
  JSON-RPC layer must only touch this module and the router mount.

  The caller's `Switchboard.Scope` arrives in the frame assigns (`:current_scope`), put there by
  `SwitchboardWeb.Plugs.MCPAuth` for every HTTP request.
  """

  use Anubis.Server,
    name: "switchboard",
    version: Mix.Project.config()[:version],
    capabilities: [:tools]

  alias Anubis.MCP.Error
  alias Anubis.Server.Component.Tool
  alias Anubis.Server.Response
  alias Switchboard.Scope
  alias Switchboard.Tools

  require Logger

  @impl true
  def init(client_info, frame) do
    Logger.info(
      "MCP initialize from #{inspect(client_info["name"])} #{inspect(client_info["version"])}"
    )

    {:ok, frame}
  end

  @impl true
  def server_instructions, do: Switchboard.MCP.Instructions.text()

  @impl true
  def server_tools(_compiled, frame) do
    case frame.assigns[:current_scope] do
      %Scope{} = scope -> Enum.map(Tools.available(scope), &to_tool/1)
      _ -> []
    end
  end

  @impl true
  def handle_tool_call(name, args, frame) do
    case frame.assigns[:current_scope] do
      %Scope{} = scope ->
        case Tools.run(scope, name, args || %{}) do
          {:ok, markdown} -> {:reply, Response.text(Response.tool(), markdown), frame}
          {:error, message} -> {:reply, Response.tool() |> Response.error(message), frame}
        end

      _ ->
        {:error, Error.protocol(:invalid_request, %{message: "unauthenticated"}), frame}
    end
  end

  defp to_tool(mod) do
    %Tool{
      name: mod.name(),
      title: mod.title(),
      description: mod.description(),
      input_schema: mod.input_schema(),
      annotations: annotations(mod),
      # Arguments are validated by Switchboard.Tools; without a validator the library would
      # drop them and pass an empty map.
      validate_input: &{:ok, &1}
    }
  end

  defp annotations(mod) do
    a = mod.annotations()

    %{
      "title" => mod.title(),
      "readOnlyHint" => a.read_only,
      "destructiveHint" => Map.get(a, :destructive, not a.read_only),
      "idempotentHint" => Map.get(a, :idempotent, a.read_only),
      "openWorldHint" => Map.get(a, :open_world, true)
    }
  end
end
