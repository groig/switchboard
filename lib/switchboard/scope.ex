defmodule Switchboard.Scope do
  @moduledoc """
  Who is calling, and through what. Every tool call and every upstream request receives one.

  * `user` - the `Switchboard.Accounts.User`.
  * `client_id` / `client_name` - the MCP client (an OAuth client, or `nil` for a personal token).
  * `via` - `:oauth`, `:personal_token` or `:browser`.
  * `ip` - the client address (behind the proxy), for the audit log.
  """
  alias Switchboard.Accounts.User

  @enforce_keys [:user]
  defstruct [:user, :client_id, :client_name, :grant_id, :ip, via: :oauth]

  @type t :: %__MODULE__{
          user: User.t() | nil,
          client_id: String.t() | nil,
          client_name: String.t() | nil,
          grant_id: Ecto.UUID.t() | nil,
          ip: String.t() | nil,
          via: :oauth | :personal_token | :browser
        }

  def for_user(%User{} = user, opts \\ []),
    do: struct!(__MODULE__, Keyword.put(opts, :user, user))
end
