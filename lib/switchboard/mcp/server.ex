defmodule Switchboard.MCP.Server do
  @moduledoc """
  The adapter between `anubis_mcp` and Switchboard's tools and workflows. **This is the only
  module that knows the MCP library**: it turns `Switchboard.Tool` modules into protocol tool
  definitions and dispatches `tools/call` to `Switchboard.Tools.run/3`, and turns
  `Switchboard.Workflow` modules into prompts (slash commands) whose `prompts/get` goes to
  `Switchboard.Workflows.run/4`. Swapping the library for our own JSON-RPC layer must only touch
  this module and the router mount.

  anubis has no per-request filter for prompts (as `server_tools/2` is for tools), so the
  prompts are registered on the frame in `init/2`: on every request in the stateless era, once
  per session in the 2025-06-18 era. A workflow switched off later in a legacy session stays
  listed there, and `Workflows.run/4` refuses it.

  The caller's `Switchboard.Scope` arrives in the frame assigns (`:current_scope`), put there by
  `SwitchboardWeb.Plugs.MCPAuth` for every HTTP request.
  """

  use Anubis.Server,
    name: "switchboard",
    version: Mix.Project.config()[:version],
    capabilities: [:tools, :prompts, :completion]

  alias Anubis.MCP.Error
  alias Anubis.Server.Component.Prompt
  alias Anubis.Server.Component.Tool
  alias Anubis.Server.Response
  alias Switchboard.{RateLimit, Scope, Tools, Workflows}

  require Logger

  @impl true
  def init(client_info, frame) do
    Logger.info(
      "MCP initialize from #{inspect(client_info["name"])} #{inspect(client_info["version"])}"
    )

    {:ok, register_prompts(frame)}
  end

  defp register_prompts(frame) do
    case frame.assigns[:current_scope] do
      %Scope{} = scope ->
        prompts = Map.new(Workflows.available(scope), &{&1.name(), to_prompt(&1)})
        %{frame | prompts: prompts}

      _ ->
        frame
    end
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
          {:ok, markdown} when is_binary(markdown) ->
            {:reply, Response.text(Response.tool(), markdown), frame}

          # Text first: clients that can't show images still read it.
          {:ok, %{text: text, images: images}} ->
            response =
              Enum.reduce(images, Response.text(Response.tool(), text), fn image, r ->
                Response.image(r, Base.encode64(image.data), image.mime_type)
              end)

            {:reply, response, frame}

          {:error, message} ->
            {:reply, Response.tool() |> Response.error(message), frame}
        end

      _ ->
        {:error, Error.protocol(:invalid_request, %{message: "unauthenticated"}), frame}
    end
  end

  @impl true
  def handle_prompt_get(name, args, frame) do
    case frame.assigns[:current_scope] do
      %Scope{} = scope ->
        case Workflows.run(scope, name, args || %{}, :prompt) do
          {:ok, text} ->
            {:reply, Response.prompt(Workflows.description(name)) |> Response.user_message(text),
             frame}

          {:error, message} ->
            {:error, Error.execution(message), frame}
        end

      _ ->
        {:error, Error.protocol(:invalid_request, %{message: "unauthenticated"}), frame}
    end
  end

  # Argument completion for prompts: `task` offers the caller's open Plane items.
  @impl true
  def handle_completion(
        %{"type" => "ref/prompt", "name" => name},
        %{"name" => arg} = argument,
        frame
      ) do
    values =
      with %Scope{} = scope <- frame.assigns[:current_scope],
           :ok <- RateLimit.take({scope.user.id, "completion"}, 60) do
        Workflows.complete(scope, name, arg, argument["value"] || "")
      else
        _ -> []
      end

    {:reply, Response.completion() |> Response.completion_values(values), frame}
  end

  def handle_completion(_ref, _argument, frame),
    do: {:reply, Response.completion() |> Response.completion_values([]), frame}

  defp to_prompt(mod) do
    %Prompt{
      name: mod.name(),
      title: mod.title(),
      description: mod.description(),
      arguments:
        Enum.map(mod.arguments(), fn a ->
          %{"name" => a.name, "description" => a.description, "required" => a.required}
        end),
      # As for tools: Switchboard.Workflows validates; without this the library drops them.
      validate_input: &{:ok, &1}
    }
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
