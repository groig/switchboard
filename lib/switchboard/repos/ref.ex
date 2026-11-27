defmodule Switchboard.Repos.Ref do
  @moduledoc """
  A repository, resolved to where it lives (`Switchboard.Repos.resolve/2`): `host` is `:forgejo`
  or `:github`. A URL may also carry a pull request or run number (`pr`, `run`).
  """
  @enforce_keys [:host, :owner, :name]
  defstruct [:host, :owner, :name, :pr, :run]

  @type t :: %__MODULE__{
          host: :forgejo | :github,
          owner: String.t(),
          name: String.t(),
          pr: pos_integer() | nil,
          run: pos_integer() | nil
        }

  @doc "`owner/name`."
  def full(%__MODULE__{owner: o, name: n}), do: "#{o}/#{n}"

  @doc "What to store so the same repository resolves the same way later: `github:` when on GitHub."
  def stored(%__MODULE__{host: :github} = ref), do: "github:" <> full(ref)
  def stored(%__MODULE__{} = ref), do: full(ref)
end
