defmodule Switchboard.Encrypted.Map do
  @moduledoc """
  An Ecto type for a map of secrets, encrypted with `Switchboard.Vault`. Declare fields of this
  type with `redact: true` so the plaintext never shows in `inspect/1`, logs or crash reports.
  """
  use Cloak.Ecto.Map, vault: Switchboard.Vault
end
