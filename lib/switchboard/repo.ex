defmodule Switchboard.Repo do
  use Ecto.Repo,
    otp_app: :switchboard,
    adapter: Ecto.Adapters.Postgres
end
