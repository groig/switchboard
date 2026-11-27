defmodule Switchboard.Tools do
  @moduledoc """
  The registry of MCP tools, and the single entry point that runs one.

  `run/3` applies the cross-cutting policy (kill switches, read-only mode, rate limits, audit,
  telemetry); the MCP adapter calls it and nothing else.
  """

  alias Switchboard.{Audit, Controls, RateLimit, Scope}

  require Logger

  @tools [
    Switchboard.Tools.Whoami,
    Switchboard.Tools.MyWork,
    Switchboard.Tools.TaskStatus,
    Switchboard.Tools.Release,
    Switchboard.Tools.PlaneSearch,
    Switchboard.Tools.PlaneGetItem,
    Switchboard.Tools.PlaneGetImage,
    Switchboard.Tools.PlaneMyItems,
    Switchboard.Tools.PrStatus,
    Switchboard.Tools.CiFailure,
    Switchboard.Tools.RepoSearchPrs,
    Switchboard.Tools.ErrorList,
    Switchboard.Tools.ErrorGet,
    Switchboard.Tools.DocsSearch,
    Switchboard.Tools.DocsRead,
    Switchboard.Tools.ChatInbox,
    Switchboard.Tools.ChatRead,
    # Writes (confirm first) and notifications.
    Switchboard.Tools.PlaneComment,
    Switchboard.Tools.PlaneSetState,
    Switchboard.Tools.ErrorResolve,
    Switchboard.Tools.ErrorIgnore,
    Switchboard.Tools.DocsDraft,
    Switchboard.Tools.SendMessage,
    Switchboard.Tools.NotifyMe,
    # Watches: DMs to the caller when something finishes (writes that only affect the caller).
    Switchboard.Tools.WatchCi,
    Switchboard.Tools.WatchTask,
    Switchboard.Tools.WatchRelease,
    Switchboard.Tools.ListWatches,
    Switchboard.Tools.CancelWatch,
    # Team workflows for clients without MCP prompts (Switchboard.Workflows).
    Switchboard.Tools.Workflow
  ]

  # Tests register extra tools (e.g. a write tool for the policy matrix) through config.
  @extra Application.compile_env(:switchboard, [__MODULE__, :extra], [])

  @doc "All tool modules, in a stable order."
  def all, do: Enum.sort_by(@tools ++ @extra, & &1.name())

  @doc """
  Tools the scope may list: enabled ones, minus write tools in read-only mode. Calling a hidden
  tool still goes through `run/3`, which refuses it with a reason.
  """
  def available(%Scope{}) do
    read_only? = Controls.read_only?()

    Enum.filter(all(), fn mod ->
      Controls.tool_enabled?(mod.name()) and (not read_only? or mod.annotations()[:read_only])
    end)
  end

  def fetch(name) when is_binary(name) do
    case Enum.find(all(), &(&1.name() == name)) do
      nil -> :error
      mod -> {:ok, mod}
    end
  end

  @doc """
  Runs a tool for the scope. This is the single place for cross-cutting policy, in order:

    1. the tool exists and its kill switch is on;
    2. read-only mode refuses tools that aren't read-only;
    3. the per-person, per-tool rate limit (token bucket);
    4. argument validation against the input schema;
    5. the call itself, timed, with a `[:switchboard, :tool, :call]` telemetry event;
    6. one audit row whatever the outcome.

  A tool that hands over to `Switchboard.Workflows.run/4` (the `workflow` tool) is audited there,
  once, as `workflow:<name>`; its refusals here (kill switch, rate limit, arguments) are audited
  here as usual.

  The maintenance message, when set, is prepended to successful results (to the text of a
  result with images). The audit row's size counts the image bytes too.
  """
  @spec run(Scope.t(), String.t(), map()) ::
          {:ok, String.t()} | {:ok, Switchboard.Tool.rich()} | {:error, String.t()}
  def run(%Scope{} = scope, name, args) when is_map(args) do
    started = System.monotonic_time()
    Process.delete(:switchboard_audited)

    {outcome, result, mod} =
      with {:ok, mod} <- fetch_or_unknown(name),
           :ok <- check_enabled(mod),
           :ok <- check_read_only(mod),
           :ok <- check_rate(scope, mod),
           :ok <- validate_args(mod.input_schema(), args) |> tag(:error, mod) do
        Process.put(:switchboard_upstreams, [])

        case safe_call(mod, scope, args) do
          # A workflow's text already carries the maintenance notice.
          {:ok, markdown} when is_binary(markdown) ->
            if Process.get(:switchboard_audited),
              do: {"ok", {:ok, markdown}, mod},
              else: {"ok", {:ok, with_notice(markdown)}, mod}

          {:ok, %{text: text, images: images} = rich} when is_binary(text) and is_list(images) ->
            {"ok", {:ok, %{rich | text: with_notice(text)}}, mod}

          {:error, message} ->
            {"error", {:error, to_string(message)}, mod}
        end
      end
      |> case do
        {outcome, _result, _mod} = done when is_binary(outcome) -> done
        {:refused, outcome, message, mod} -> {outcome, {:error, message}, mod}
      end

    duration_ms =
      System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

    upstreams = Process.delete(:switchboard_upstreams) || []

    :telemetry.execute(
      [:switchboard, :tool, :call],
      %{duration: System.monotonic_time() - started},
      %{tool: name, outcome: outcome}
    )

    {error, result_bytes} =
      case result do
        {:ok, markdown} when is_binary(markdown) -> {nil, byte_size(markdown)}
        {:ok, %{text: text, images: images}} -> {nil, byte_size(text) + image_bytes(images)}
        {:error, message} -> {message, nil}
      end

    unless Process.delete(:switchboard_audited) do
      Audit.log_tool(scope, name, args,
        outcome: outcome,
        error: error,
        duration_ms: duration_ms,
        result_bytes: result_bytes,
        upstreams: upstreams,
        sensitive: sensitive_args(mod)
      )
    end

    result
  end

  @doc "Records that the current tool call reached an upstream (for the audit row)."
  def note_upstream(system) do
    case Process.get(:switchboard_upstreams) do
      nil -> :ok
      seen -> Process.put(:switchboard_upstreams, Enum.uniq([to_string(system) | seen]))
    end
  end

  defp fetch_or_unknown(name) do
    case fetch(name) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:refused, "error", "Unknown tool: #{name}", nil}
    end
  end

  defp check_enabled(mod) do
    if Controls.tool_enabled?(mod.name()),
      do: :ok,
      else: {:refused, "disabled", "#{mod.name()} is turned off by an administrator.", mod}
  end

  defp check_read_only(mod) do
    if Controls.read_only?() and not mod.annotations()[:read_only],
      do:
        {:refused, "disabled",
         "Switchboard is in read-only mode; #{mod.name()} changes data and is unavailable.", mod},
      else: :ok
  end

  defp check_rate(%Scope{user: user}, mod) do
    case RateLimit.take({user.id, mod.name()}, Controls.rate_limit(mod)) do
      :ok ->
        :ok

      {:error, ms} ->
        {:refused, "rate_limited",
         "Rate limit reached for #{mod.name()}. Try again in #{max(div(ms, 1000), 1)} s.", mod}
    end
  end

  defp tag(:ok, _outcome, _mod), do: :ok
  defp tag({:error, message}, outcome, mod), do: {:refused, to_string(outcome), message, mod}

  # A crashing tool is an error result for the agent, never a crashed request.
  defp safe_call(mod, scope, args) do
    mod.call(scope, args)
  rescue
    e ->
      Logger.error("Tool #{mod.name()} crashed: " <> Exception.format(:error, e, __STACKTRACE__))
      {:error, "#{mod.name()} failed unexpectedly. The error was logged."}
  end

  defp image_bytes(images), do: Enum.reduce(images, 0, &(byte_size(&1.data) + &2))

  defp with_notice(markdown) do
    case Controls.maintenance_message() do
      nil -> markdown
      msg -> "> **Maintenance:** #{msg}\n\n" <> markdown
    end
  end

  defp sensitive_args(nil), do: []

  defp sensitive_args(mod) do
    if function_exported?(mod, :sensitive_args, 0), do: mod.sensitive_args(), else: []
  end

  # Required keys and primitive types. Tools validate their own semantics.
  defp validate_args(%{"properties" => props} = schema, args) do
    missing = Enum.reject(Map.get(schema, "required", []), &Map.has_key?(args, &1))
    unknown = Map.keys(args) -- Map.keys(props)

    bad_types =
      for {key, value} <- args, spec = props[key], not type_ok?(spec, value), do: key

    cond do
      missing != [] -> {:error, "Missing arguments: #{Enum.join(missing, ", ")}"}
      unknown != [] -> {:error, "Unknown arguments: #{Enum.join(unknown, ", ")}"}
      bad_types != [] -> {:error, "Invalid arguments: #{Enum.join(bad_types, ", ")}"}
      true -> :ok
    end
  end

  defp validate_args(_schema, args) when map_size(args) == 0, do: :ok
  defp validate_args(_schema, _args), do: {:error, "This tool takes no arguments"}

  defp type_ok?(%{"enum" => values}, v), do: v in values

  defp type_ok?(%{"type" => types}, v) when is_list(types),
    do: Enum.any?(types, &type_ok?(%{"type" => &1}, v))

  defp type_ok?(%{"type" => "string"}, v), do: is_binary(v)
  defp type_ok?(%{"type" => "integer"}, v), do: is_integer(v)
  defp type_ok?(%{"type" => "number"}, v), do: is_number(v)
  defp type_ok?(%{"type" => "boolean"}, v), do: is_boolean(v)
  defp type_ok?(%{"type" => "array"}, v), do: is_list(v)
  defp type_ok?(%{"type" => "object"}, v), do: is_map(v)
  defp type_ok?(_, _), do: true
end
