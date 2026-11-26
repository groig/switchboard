# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Ecto's query log prints parameter values (plaintext secrets before encryption), so it is off;
# Switchboard.Repo.QueryLog logs queries without them.
config :switchboard, Switchboard.Repo, log: false

config :switchboard,
  ecto_repos: [Switchboard.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

config :switchboard, :public_url, "http://localhost:#{System.get_env("PORT", "4000")}"

# Who may sign in. Empty here: each environment sets it (runtime.exs reads it from the environment).
config :switchboard, Switchboard.Accounts,
  allowed_forgejo_orgs: [],
  # "Org/team" names; members of these teams may sign in too.
  allowed_forgejo_teams: [],
  admin_usernames: []

# Upstream systems. Their URLs (and Plane's workspace) come from the environment (runtime.exs);
# there are no defaults here.
config :switchboard, Switchboard.Upstreams,
  # Concurrency limits and circuit breakers per upstream (Switchboard.Upstreams.Guard).
  guard: [
    max_concurrency: 8,
    acquire_timeout: 3_000,
    threshold: 5,
    cooldown: 30_000,
    plane: [max_concurrency: 4]
  ]

config :switchboard, Switchboard.Audit, retention_days: 180

config :switchboard, Oban,
  engine: Oban.Engines.Basic,
  repo: Switchboard.Repo,
  queues: [default: 5],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Plugins.Cron, crontab: [{"23 3 * * *", Switchboard.Audit.Prune}]}
  ]

# Never log credential-like parameters (Phoenix matches these as substrings of the key).
config :phoenix, :filter_parameters, [
  "password",
  "secret",
  "token",
  "api_key",
  "key",
  "code",
  "verifier",
  "authorization",
  "credential",
  "user_id"
]

# Configure the endpoint
config :switchboard, SwitchboardWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SwitchboardWeb.ErrorHTML, json: SwitchboardWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Switchboard.PubSub,
  live_view: [signing_salt: "eIW4/bbN"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :switchboard, Switchboard.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  switchboard: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  switchboard: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
