defmodule Switchboard.Vault do
  @moduledoc """
  Encrypts secrets at rest (upstream credentials) with AES-256-GCM through `cloak_ecto`.

  Keys come from the environment (`config/runtime.exs`):

    * `CLOAK_KEY` - the current key (base64, 32 bytes); new values are encrypted with it.
    * `CLOAK_RETIRED_KEYS` - optional, comma-separated old keys that can still decrypt.

  Each ciphertext carries its key tag, so rotating is: set the new `CLOAK_KEY`, move the old one
  to `CLOAK_RETIRED_KEYS`, restart, run `Switchboard.Vault.reencrypt_all/0`, then drop the
  retired key.
  """
  use Cloak.Vault, otp_app: :switchboard

  @impl GenServer
  def init(config) do
    {:ok, Keyword.put(config, :ciphers, ciphers())}
  end

  defp ciphers do
    keys = Application.get_env(:switchboard, __MODULE__, [])
    retired = Keyword.get(keys, :retired_keys, [])

    [{:default, cipher(Keyword.fetch!(keys, :key))}] ++
      Enum.with_index(retired, fn key, i -> {:"retired_#{i}", cipher(key)} end)
  end

  defp cipher(base64) do
    key = Base.decode64!(base64)
    32 = byte_size(key)
    # The tag identifies the key (a short hash), so rotation does not depend on order.
    tag = "sb" <> Base.encode16(binary_part(:crypto.hash(:sha256, key), 0, 4))
    {Cloak.Ciphers.AES.GCM, tag: tag, key: key, iv_length: 12}
  end

  @doc "Re-encrypts every stored secret with the current key (after a rotation)."
  def reencrypt_all do
    Switchboard.Connections.reencrypt_all()
  end
end
