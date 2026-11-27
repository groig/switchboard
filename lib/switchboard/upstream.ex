defmodule Switchboard.Upstream do
  @moduledoc """
  The behaviour each upstream adapter implements for the Connections page.

  `whoami/1` checks a credential and reports who it belongs to, as
  `%{"username" => ..., "email" => ..., "name" => ...}` (any may be nil), so the page can warn
  when a pasted key belongs to someone else.
  """

  @typedoc "A form field the person fills in to link the system."
  @type field :: %{name: String.t(), label: String.t(), secret?: boolean()}

  @callback system() :: String.t()
  @callback label() :: String.t()
  @doc "Link to the page where the person creates the key (nil when there is nothing to paste)."
  @callback key_url() :: String.t() | nil
  @doc "The minimum permissions the key needs, in one line."
  @callback permissions() :: String.t()
  @callback fields() :: [field()]
  @callback whoami(secret :: map()) ::
              {:ok, map()} | {:error, :unauthorized | :timeout | term()}

  @doc "Whether the system is set up on this server (hidden everywhere when not). Default true."
  @callback enabled?() :: boolean()

  @doc """
  For a system linked through an OAuth flow in the browser instead of a pasted key: the path
  that starts it (the Connections page shows a Connect button).
  """
  @callback connect_path() :: String.t()

  @doc "Only some people need it (onboarding doesn't count it as missing). Default false."
  @callback optional?() :: boolean()

  @optional_callbacks enabled?: 0, connect_path: 0, optional?: 0
end
