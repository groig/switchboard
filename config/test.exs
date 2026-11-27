import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :switchboard, Switchboard.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "switchboard_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :switchboard, SwitchboardWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "o73WlGJYOwnkaLNY05tyqT0KGrDLKfxGy9B+5a5f3v44VV3etktAovYJxsI9cGD3",
  server: false

# In test we don't send emails
config :switchboard, Switchboard.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :switchboard, :public_url, "http://localhost:4002"

config :switchboard, Switchboard.Vault, key: "q3y8Qy3c8Ghw4mKxk8ZQ3Cqv7P0mW1sV9tYbN2aD5eM="

# Jobs run only when a test asks for them (Oban.Testing).
config :switchboard, Oban, testing: :manual

config :switchboard, Switchboard.Accounts, allowed_forgejo_orgs: ["Acme"]

config :switchboard, Switchboard.Upstreams,
  plane: [url: "http://plane.test", workspace: "acme"],
  argus: [url: "http://argus.test"],
  outline: [url: "http://outline.test"],
  rocketchat: [
    url: "http://chat.test",
    bot_user_id: "bot-id",
    bot_token: "bot-token",
    route_budget: 100_000
  ],
  releases: [url: "http://releases.test", token: "releases-token"],
  # Generous limits so async tests never trip each other's breakers; guard tests set their own.
  guard: [max_concurrency: 1_000, acquire_timeout: 1_000, threshold: 1_000, cooldown: 1_000],
  req_options: [plug: {Req.Test, Switchboard.Upstreams}]

config :switchboard, Switchboard.Forgejo,
  url: "http://forgejo.test",
  client_id: "test-client",
  client_secret: "test-secret",
  req_options: [plug: {Req.Test, Switchboard.Forgejo}]

# CIMD fetches go to a Req.Test stub; tests set the resolver they need.
# GitHub's web and API hosts are answered by the Switchboard.Upstreams stub too.
config :switchboard, Switchboard.GitHub,
  url: "http://github.test",
  api_url: "http://api.github.test",
  client_id: "gh-client",
  client_secret: "gh-secret",
  owners: ["example-org"]

config :switchboard, Switchboard.OAuth.CIMD,
  req_options: [plug: {Req.Test, Switchboard.OAuth.CIMD}],
  resolver: &Switchboard.OAuthFixtures.public_resolver/1

# Controls are read from the database on every call (no shared cache between async tests).
config :switchboard, Switchboard.Controls, cache: false
config :switchboard, Switchboard.Stats, cache: false

# A write tool for the policy tests (test/support/test_tools.ex).
config :switchboard, Switchboard.Tools, extra: [Switchboard.TestTools.Note]

# Short fan-out budgets so slow-upstream tests finish quickly.
config :switchboard, Switchboard.FanOut, max_timeout: 600

config :switchboard, :forgejo_webhook_secret, "hook-secret"
