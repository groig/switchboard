# Switchboard

Switchboard connects Claude Code and Codex to Plane, Forgejo, Argus, Outline, Rocket.Chat and a releases feed through one remote MCP endpoint. Developers link their own accounts. Switchboard checks permissions and records each tool call in the audit log.

## Primeros pasos

1. Sustituye el dominio del ejemplo por el de tu organización. Ejecuta el bloque correspondiente a tu cliente.
2. Inicia sesión con Forgejo en el navegador y autoriza el acceso. En Claude Code, ejecuta el comando de inicio de sesión desde una terminal interactiva.
3. Abre `/connections` en Switchboard y vincula tus credenciales para los servicios que vayas a usar. Pídele al asistente que ejecute `whoami` para comprobar la identidad con la que accede.
4. Usa los comandos de equipo. En Claude Code se escriben como `/mcp__switchboard__<nombre>`. En Codex, pídelo con tus palabras (por ejemplo «haz mi standup») y el asistente usará la herramienta `workflow`. Los comandos no cambian nada por sí solos: el asistente te enseña cada mensaje o cambio y espera tu confirmación.

| Comando | Para qué | Ejemplo en Claude Code |
|---|---|---|
| `standup` | Redactar tu standup: ayer, hoy y bloqueos | `/mcp__switchboard__standup #equipo-standup` |
| `next` | Qué hacer ahora: como mucho 5 cosas, con el motivo | `/mcp__switchboard__next` |
| `inbox` | Todo lo que te espera: mensajes, revisiones, tareas y avisos | `/mcp__switchboard__inbox` |
| `pickup` | Empezar una tarea: qué se pide, dónde tocar el código y nombre de rama | `/mcp__switchboard__pickup PROJ-123` |
| `triage` | Por qué ocurre un error de Argus y cómo arreglarlo | `/mcp__switchboard__triage demo-api/7` |
| `handoff` | Pasar una tarea a QA con un mensaje de pruebas | `/mcp__switchboard__handoff PROJ-123 #qa` |

## Getting started

1. Replace the example domain with your organization's Switchboard host. Run the block for your client.
2. Sign in with Forgejo in the browser and approve access. Run the Claude Code login command in an interactive terminal.
3. Open `/connections` on your Switchboard host and link your credentials for the services you use. Ask your assistant to run `whoami` to verify your identity.
4. Use the team commands. In Claude Code, type them as `/mcp__switchboard__<name>`. In Codex, ask in your own words (for example "do my standup") and the assistant uses the `workflow` tool. The commands change nothing on their own: the assistant shows you each message or change and waits for your OK.

| Command | What for | Claude Code example |
|---|---|---|
| `standup` | Draft your standup: yesterday, today, blockers | `/mcp__switchboard__standup #team-standup` |
| `next` | What to do now: at most 5 things, each with a reason | `/mcp__switchboard__next` |
| `inbox` | Everything waiting for you: messages, reviews, tasks and watches | `/mcp__switchboard__inbox` |
| `pickup` | Start a task: what's asked, where the code goes, a branch name | `/mcp__switchboard__pickup PROJ-123` |
| `triage` | Why an Argus error happens and how to fix it | `/mcp__switchboard__triage demo-api/7` |
| `handoff` | Hand a task over to QA with a test plan | `/mcp__switchboard__handoff PROJ-123 #qa` |

**Claude Code**

```sh
claude mcp add --transport http switchboard https://switchboard.example.com/mcp
claude mcp login switchboard
```

**Codex**

```sh
codex mcp add switchboard --url https://switchboard.example.com/mcp
```

## Project status

| Milestone | State |
|---|---|
| 1. Remote MCP and OAuth through Caddy | Tested with Claude Code and Codex |
| 2. Forgejo login, connections, personal tokens, audit, admin controls and bilingual UI | Implemented |
| 3. Read tools and cross-system queries | Implemented |
| 4. Writes and notifications | Implemented with per-tool policy tests |
| 5. Watches and reading Rocket.Chat | Implemented: CI, task and release watches (polling plus Forgejo webhook), `chat_inbox`, `chat_read` |
| 6. Team workflows as slash commands | Implemented: `standup`, `next`, `inbox`, `pickup`, `triage`, `handoff` as MCP prompts and the `workflow` tool |
| Deployment | Release image, Compose example, health check and CI workflow included |

## Development / Desarrollo

With Elixir, Erlang/OTP and PostgreSQL running locally, use the commands below. The default database login is `postgres` with password `postgres`. Visit <http://localhost:4310> and choose **Sign in with Forgejo** to use the built-in development account. Development uses example upstream URLs and synthetic release data.

Con Elixir, Erlang/OTP y PostgreSQL disponibles en tu equipo, ejecuta estos comandos. La conexión local a PostgreSQL usa `postgres` como usuario y contraseña. Abre <http://localhost:4310> e inicia sesión con Forgejo para entrar con la cuenta de desarrollo. Las direcciones de los servicios son de ejemplo y los datos de versiones son ficticios.

```sh
mix setup
PORT=4310 mix phx.server
```

Use `http://localhost:4310/mcp` for local client registration. For real Forgejo sign-in, set the three Forgejo OAuth variables below and register `http://localhost:4310/auth/forgejo/callback`. Set `PUBLIC_URL` when accessing the server through a proxy. Use your own linked credentials for read-only development against real systems. Visit `/dev/design` for the design system and `/dev/dashboard` for LiveDashboard. Run `mix precommit` before committing.

## Deployment / Despliegue

Copy `.env.example` to `.env`, fill in your deployment's values and create or select the external Docker network used by the releases feed. Register the Forgejo callback at the public origin under `/auth/forgejo/callback`. Run the command below. The app migrates PostgreSQL at startup. Configure your TLS reverse proxy to forward to `127.0.0.1:19300` and stream MCP responses without buffering.

Copia `.env.example` a `.env`, completa los valores y selecciona o crea la red externa de Docker que comunica con el servicio de versiones. Registra en Forgejo la URL pública de retorno con la ruta `/auth/forgejo/callback`. Ejecuta el siguiente comando. La aplicación aplica las migraciones al arrancar. Configura el proxy TLS para reenviar las peticiones a `127.0.0.1:19300` y transmitir las respuestas MCP sin almacenarlas en búfer.

```sh
docker compose -f compose.example.yml up -d
```

## Configuration

Production boot reports missing required settings together.

| Required for the app | Purpose |
|---|---|
| `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST` | PostgreSQL connection URI, Phoenix signing secret (`mix phx.gen.secret`) and public hostname |
| `CLOAK_KEY` | Encryption key for linked credentials. Generate with `openssl rand -base64 32` |
| `FORGEJO_URL`, `FORGEJO_CLIENT_ID`, `FORGEJO_CLIENT_SECRET` | Forgejo base URL and confidential OAuth application |
| `ALLOWED_FORGEJO_ORGS` or `ALLOWED_FORGEJO_TEAMS` | At least one sign-in allowlist. Use comma-separated orgs or `Org/team` names |
| `ADMIN_USERNAMES` | Comma-separated Forgejo usernames for administrators |
| `PLANE_URL`, `PLANE_WORKSPACE`, `ARGUS_URL`, `OUTLINE_URL`, `ROCKETCHAT_URL` | Upstream base URLs and Plane workspace slug |
| `ROCKETCHAT_BOT_USER_ID`, `ROCKETCHAT_BOT_TOKEN` | Bot identity and personal access token for `notify_me` and watch notices |
| `RELEASES_URL`, `RELEASES_TOKEN` | Releases feed endpoint and access token |

| Optional for the app | Purpose |
|---|---|
| `PUBLIC_URL` | Public OAuth issuer and resource origin. Defaults to HTTPS on `PHX_HOST` |
| `CLOAK_RETIRED_KEYS` | Comma-separated previous encryption keys for rotation |
| `TRUSTED_PROXIES` | CIDRs trusted to supply the forwarded client IP. Defaults to loopback |
| `ADMIN_NETWORKS` | Restrict admin access to these CIDRs |
| `HEALTH_NETWORKS` | Additional peer CIDRs allowed to query `/healthz`. The default permits the direct loopback check |
| `FORGEJO_WEBHOOK_SECRET` | Secret of the Forgejo webhook at `/hooks/forgejo`. Without it the endpoint refuses requests and watches poll Forgejo (1 to 5 minutes later) |
| `ROCKETCHAT_ROUTE_BUDGET` | Calls a minute per Rocket.Chat REST route that Switchboard makes with people's own tokens, all people together (default 8). Rocket.Chat limits each route per client IP, so keep it a little below the server's limit, e.g. 50 when Rocket.Chat allows 60 a minute |
| `AUDIT_RETENTION_DAYS`, `POOL_SIZE` | Audit retention in days (180) and database pool size (10) |

Compose requires `SWITCHBOARD_TAG` (published image tag), `POSTGRES_PASSWORD` (use a URL-safe password), `RELEASES_NETWORK` (existing Docker network name) and an explicit `TRUSTED_PROXIES` for your proxy. It constructs `DATABASE_URL` for the bundled database.

### Forgejo webhook for CI watches

Optional; it makes `watch_ci` notices arrive within seconds instead of minutes. In Forgejo, add a
system webhook (Site administration → Integrations → System webhooks) or one per organization
(Settings → Webhooks), of type **Forgejo**:

- Target URL: `https://<switchboard host>/hooks/forgejo`, method POST.
- POST content type: `application/json` (form-encoded payloads are refused).
- Secret: the value of `FORGEJO_WEBHOOK_SECRET`.
- Trigger on: **Custom events…**, then under **Action Run events** tick **Failure** and
  **Success** (**Recover** may be ticked too; Forgejo 16 doesn't send it). Nothing else is needed.
- Active: on.

`/hooks/forgejo` must be reachable from Forgejo. It isn't under `/admin` or `/dev`, so the usual
proxy rules already let it through.

## Publication checks

Install Python 3 and Gitleaks v8 with the `git` subcommand. Configure each clone with paths to the private denylist (one case-insensitive regular expression per line) and the development environment file (literal shell assignments). Keep both files outside the checkout.

```sh
git config switchboard.denylist /private/path/to/denylist
git config switchboard.privateEnv /private/path/to/environment
git config core.hooksPath .githooks
```

## Documentation

- [Client protocols and OAuth behavior](docs/CLIENTS.md)
- [Architecture, authentication and upstream adapters](docs/ARCHITECTURE.md)
- [Threat model and known limitations](docs/SECURITY.md)
- [Tool and workflow reference](docs/TOOLS.md)
- [Contributor guidelines](AGENTS.md)
- [AGPL license](LICENSE)
