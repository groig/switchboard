import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/switchboard start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :switchboard, SwitchboardWeb.Endpoint, server: true
end

config :switchboard, SwitchboardWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if public_url = System.get_env("PUBLIC_URL") do
  config :switchboard, :public_url, public_url
end

# Comma-separated lists from the environment.
list_env = fn name ->
  case System.get_env(name) do
    nil -> nil
    value -> value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end
end

if key = System.get_env("CLOAK_KEY") do
  config :switchboard, Switchboard.Vault,
    key: key,
    retired_keys: list_env.("CLOAK_RETIRED_KEYS") || []
end

accounts =
  [
    allowed_forgejo_orgs: list_env.("ALLOWED_FORGEJO_ORGS"),
    allowed_forgejo_teams: list_env.("ALLOWED_FORGEJO_TEAMS"),
    admin_usernames: list_env.("ADMIN_USERNAMES")
  ]
  |> Enum.reject(fn {_k, v} -> is_nil(v) end)

if accounts != [], do: config(:switchboard, Switchboard.Accounts, accounts)

# CIDRs of the reverse proxy (X-Forwarded-For is trusted only from these), and optionally the
# networks allowed to reach /admin and /dev (on top of any restriction in the reverse proxy).
if proxies = list_env.("TRUSTED_PROXIES"), do: config(:switchboard, :trusted_proxies, proxies)
if networks = list_env.("ADMIN_NETWORKS"), do: config(:switchboard, :admin_networks, networks)

# Shared secret of the Forgejo webhook (POST /hooks/forgejo). Optional: without it the endpoint
# refuses every request and watches rely on polling.
if secret = System.get_env("FORGEJO_WEBHOOK_SECRET") do
  if secret != "", do: config(:switchboard, :forgejo_webhook_secret, secret)
end

if days = System.get_env("AUDIT_RETENTION_DAYS") do
  config :switchboard, Switchboard.Audit, retention_days: String.to_integer(days)
end

# Calls a minute per Rocket.Chat REST route that Switchboard makes with people's own tokens, all
# of them together (Rocket.Chat rate-limits per route and client IP). Default 8, under
# Rocket.Chat's default of 10; raise it when the server's limit is raised. Any environment.
case System.get_env("ROCKETCHAT_ROUTE_BUDGET") do
  value when value in [nil, ""] ->
    :ok

  value ->
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 ->
        config :switchboard, Switchboard.Upstreams, rocketchat: [route_budget: n]

      _ ->
        raise "ROCKETCHAT_ROUTE_BUDGET must be a positive integer (calls a minute per route)"
    end
end

# GitHub (optional, any environment): an OAuth App per deployment, and the owners whose
# repositories live on GitHub. Without the client id and secret, GitHub is off: no connection,
# and `owner/repo` always means Forgejo. GITHUB_URL / GITHUB_API_URL are for GitHub Enterprise.
github =
  [
    client_id: System.get_env("GITHUB_CLIENT_ID"),
    client_secret: System.get_env("GITHUB_CLIENT_SECRET"),
    owners: list_env.("GITHUB_OWNERS"),
    url: System.get_env("GITHUB_URL"),
    api_url: System.get_env("GITHUB_API_URL")
  ]
  |> Enum.reject(fn {_k, v} -> v in [nil, "", []] end)

if github != [], do: config(:switchboard, Switchboard.GitHub, github)

# Upstreams from the environment. In production every one is required (below); in development
# they override the placeholders in dev.exs. (Config deep-merges keyword lists.)
if config_env() == :dev do
  upstream_env = [
    plane: [url: "PLANE_URL", workspace: "PLANE_WORKSPACE"],
    argus: [url: "ARGUS_URL"],
    outline: [url: "OUTLINE_URL"],
    rocketchat: [
      url: "ROCKETCHAT_URL",
      bot_user_id: "ROCKETCHAT_BOT_USER_ID",
      bot_token: "ROCKETCHAT_BOT_TOKEN"
    ],
    releases: [url: "RELEASES_URL", token: "RELEASES_TOKEN"]
  ]

  overrides =
    for {system, keys} <- upstream_env,
        values = for({key, var} <- keys, (v = System.get_env(var)) not in [nil, ""], do: {key, v}),
        values != [],
        do: {system, values}

  if overrides != [], do: config(:switchboard, Switchboard.Upstreams, overrides)

  # Development signs in against the built-in fake Forgejo, unless a real Forgejo OAuth app is
  # configured with these three.
  forgejo = Enum.map(~w(FORGEJO_URL FORGEJO_CLIENT_ID FORGEJO_CLIENT_SECRET), &System.get_env/1)

  if Enum.all?(forgejo, &(&1 not in [nil, ""])) do
    [url, client_id, client_secret] = forgejo

    config :switchboard, Switchboard.Forgejo,
      url: url,
      client_id: client_id,
      client_secret: client_secret
  end
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :switchboard, SwitchboardWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/switchboard_web/router\.ex$"E,
        ~r"lib/switchboard_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # Every deployment-specific value comes from the environment, with no defaults. Boot stops with
  # one message listing everything that is missing.
  required = ~w(
    DATABASE_URL SECRET_KEY_BASE PHX_HOST CLOAK_KEY
    FORGEJO_URL FORGEJO_CLIENT_ID FORGEJO_CLIENT_SECRET ADMIN_USERNAMES
    PLANE_URL PLANE_WORKSPACE ARGUS_URL OUTLINE_URL ROCKETCHAT_URL
    ROCKETCHAT_BOT_USER_ID ROCKETCHAT_BOT_TOKEN RELEASES_URL RELEASES_TOKEN
  )

  missing = Enum.filter(required, &(System.get_env(&1) in [nil, ""]))

  missing =
    if list_env.("ALLOWED_FORGEJO_ORGS") in [nil, []] and
         list_env.("ALLOWED_FORGEJO_TEAMS") in [nil, []],
       do: missing ++ ["ALLOWED_FORGEJO_ORGS or ALLOWED_FORGEJO_TEAMS"],
       else: missing

  if missing != [] do
    raise """
    Switchboard can't start: these environment variables are missing or empty:

    #{Enum.map_join(missing, "\n", &("  - " <> &1))}

    See the README ("Configuration") for what each one is.
    """
  end

  env = &System.fetch_env!/1
  host = env.("PHX_HOST")
  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :switchboard, Switchboard.Repo,
    url: env.("DATABASE_URL"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  config :switchboard, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")
  config :switchboard, :public_url, System.get_env("PUBLIC_URL") || "https://#{host}"

  config :switchboard, Switchboard.Forgejo,
    url: env.("FORGEJO_URL"),
    client_id: env.("FORGEJO_CLIENT_ID"),
    client_secret: env.("FORGEJO_CLIENT_SECRET")

  config :switchboard, Switchboard.Upstreams,
    plane: [url: env.("PLANE_URL"), workspace: env.("PLANE_WORKSPACE")],
    argus: [url: env.("ARGUS_URL")],
    outline: [url: env.("OUTLINE_URL")],
    rocketchat: [
      url: env.("ROCKETCHAT_URL"),
      bot_user_id: env.("ROCKETCHAT_BOT_USER_ID"),
      bot_token: env.("ROCKETCHAT_BOT_TOKEN")
    ],
    releases: [url: env.("RELEASES_URL"), token: env.("RELEASES_TOKEN")]

  # Optional CIDRs (besides the container's own loopback check) that may call /healthz.
  if networks = list_env.("HEALTH_NETWORKS"), do: config(:switchboard, :health_networks, networks)

  config :switchboard, SwitchboardWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    # Bind on all interfaces (IPv4 and IPv6) inside the container.
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: env.("SECRET_KEY_BASE")
end
