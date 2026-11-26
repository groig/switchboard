defmodule Switchboard.Workflow do
  @moduledoc """
  The behaviour of a team workflow (`standup`, `next`, `pickup`...). A workflow fetches the cheap
  facts on the server with the caller's own credentials, then returns text that tells the agent
  what to do with them. It never writes anything: any write is proposed to the user, who
  confirms it.

  Workflows know nothing about MCP. `Switchboard.Workflows.run/4` is their single policy point
  (kill switch, rate limit, argument checks, audit) and frames the text; the adapter exposes the
  result as an MCP prompt, and the `workflow` tool returns the same text for clients without
  prompts.

  `build/3` gets the scope, the validated arguments (strings) and a context map:

    * `:writes` - the write tools this workflow may propose that are available right now
      (empty in read-only mode or when they are switched off);
    * `:read_only` - whether Switchboard is in read-only mode;
    * `:locale` - the person's language (`"es"`/`"en"`) for drafts meant for colleagues;
    * `:now` - the current time (UTC).

  It returns `{:ok, %{steps: [...], facts: markdown, notes: [...]}}`: the numbered instructions for
  the agent, the prefetched facts (upstream text already wrapped as untrusted) and the notes for
  systems that failed. `{:error, message}` is for a bad argument.
  """

  alias Switchboard.Scope

  @typedoc "A prompt argument: always a string, as MCP prompt arguments are."
  @type argument :: %{name: String.t(), description: String.t(), required: boolean()}

  @type context :: %{
          writes: [String.t()],
          read_only: boolean(),
          locale: String.t(),
          now: DateTime.t()
        }

  @type built :: %{steps: [String.t()], facts: String.t(), notes: [String.t()]}

  @callback name() :: String.t()
  @callback title() :: String.t()
  @doc "One sentence: what the command is for (the prompt's description)."
  @callback description() :: String.t()
  @callback arguments() :: [argument()]
  @doc "Systems the prefetch reads (for the docs)."
  @callback connections() :: [Switchboard.Tool.connection() | :releases]
  @doc "What the prefetch reads, one line each (for the docs)."
  @callback fetches() :: [String.t()]
  @doc "Write tools the workflow may propose (the user confirms each one)."
  @callback writes() :: [String.t()]
  @callback build(Scope.t(), args :: map(), context()) :: {:ok, built()} | {:error, String.t()}
  @doc "Sample arguments and invocation for the docs."
  @callback example() :: %{args: map(), says: String.t()}
end
