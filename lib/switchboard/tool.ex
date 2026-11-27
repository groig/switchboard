defmodule Switchboard.Tool do
  @moduledoc """
  The behaviour every MCP tool implements. Tools know nothing about the MCP library: the adapter
  (`Switchboard.MCP.Server`) turns these callbacks into protocol messages.

  `call/2` receives the caller's `Switchboard.Scope` and the arguments as a map with string keys,
  already checked against `input_schema/0` for required keys and basic types. It returns compact
  Markdown written for a model to read: `{:ok, markdown}`, or `{:error, message}` for a failure
  the agent should see (it becomes an `isError` result, not a protocol error).

  A tool that returns pictures (`plane_get_image`) answers `{:ok, %{text: markdown, images:
  [%{data: bytes, mime_type: "image/png"}]}}`: the adapter sends the text block first, so a
  client that can't show images still reads it, then one image block per entry (base64).
  """

  alias Switchboard.Scope

  @typedoc """
  Behaviour hints. `read_only` tools never change upstream state; a write tool must say whether
  it is `destructive` and must tell the agent to confirm with the user first.
  """
  @type annotations :: %{
          required(:read_only) => boolean(),
          optional(:destructive) => boolean(),
          optional(:idempotent) => boolean(),
          optional(:open_world) => boolean()
        }

  @typedoc "Upstream systems a tool needs the caller to have connected."
  @type connection :: :forgejo | :plane | :argus | :outline | :rocketchat

  @callback name() :: String.t()
  @callback title() :: String.t()
  @callback description() :: String.t()
  @callback input_schema() :: map()
  @callback annotations() :: annotations()
  @callback connections() :: [connection()]
  @typedoc "Raw image bytes (not base64) and their checked MIME type."
  @type image :: %{data: binary(), mime_type: String.t()}

  @typedoc "A result with images: Markdown plus pictures."
  @type rich :: %{text: String.t(), images: [image()]}

  @callback call(Scope.t(), args :: map()) ::
              {:ok, String.t()} | {:ok, rich()} | {:error, String.t()}

  @doc """
  Argument names whose values must never be stored or logged (the audit log keeps
  `"[redacted]"`). Names that look like credentials are redacted anyway.
  """
  @callback sensitive_args() :: [String.t()]

  @doc "Sample arguments and output for `docs/TOOLS.md` (`mix switchboard.gen.tools_doc`)."
  @callback example() :: %{args: map(), output: String.t()}

  @optional_callbacks sensitive_args: 0, example: 0
end
