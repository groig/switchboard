# Architecture

```
agent ──Streamable HTTP + bearer──▶ Caddy ──▶ Switchboard (Phoenix)
                                               ├─ /mcp                       MCP endpoint (OAuth or sb_ token)
                                               ├─ /oauth/*, /.well-known/*   authorization server
                                               ├─ /auth/forgejo*             sign in with Forgejo
                                               ├─ web app (LiveView)         connections, clients, activity, profile
                                               └─ /admin, /dev               private network only (proxy rule + ADMIN_NETWORKS)
              upstreams: Forgejo · Plane · Argus · Outline · Rocket.Chat · release bot (releases feed)
```

## Layers

| Layer | Modules | Notes |
|---|---|---|
| MCP adapter | `Switchboard.MCP.Server` | The only module that references `anubis_mcp`. Lists tools per caller, forwards calls to `Tools.run/3`. |
| Tools | `Switchboard.Tool`, `Switchboard.Tools`, `Switchboard.Tools.*` | A behaviour plus a registry. `Tools.run/3` is the single policy point (below). |
| Upstreams | `Switchboard.Upstreams`, `Switchboard.Upstream`, `Switchboard.Upstreams.*` | One adapter per system. All HTTP goes through `Upstreams.request/3`. |
| Identity | `Switchboard.Accounts`, `Switchboard.Forgejo.Login`, `SwitchboardWeb.UserAuth` | Forgejo sign-in, membership checks, browser sessions. |
| Authorization server | `Switchboard.OAuth`, `Switchboard.OAuth.CIMD` | OAuth 2.1 for MCP clients (see `docs/CLIENTS.md`). |
| Credentials | `Switchboard.Connections`, `Switchboard.Vault` | Per-person upstream secrets, encrypted with `cloak_ecto`. |
| Personal tokens | `Switchboard.PersonalTokens` | `sb_...` bearer tokens for clients without OAuth. |
| Read path | `Switchboard.Plane`, `.Forgejo`, `.Argus`, `.Outline`, `.Releases`, `Switchboard.Upstreams.Guard`, `Switchboard.FanOut`, `Switchboard.Untrusted` | Read-only API clients, per-upstream limits and breakers, concurrent fan-out (below). |
| Safety | `Switchboard.Audit`, `Switchboard.Controls`, `Switchboard.RateLimit` | Append-only audit, live kill switches and read-only mode, ETS token buckets. |

### `Tools.run/3`

Every MCP tool call goes through it, in this order:

1. the tool exists and its kill switch is on (`Controls.tool_enabled?/1`);
2. read-only mode refuses tools whose annotations aren't `read_only`;
3. the per-person, per-tool token bucket (`RateLimit.take/3`, limit from `Controls.rate_limit/1`:
   60/min for reads, 10/min for writes by default, overridable per tool from `/admin`);
4. argument validation against the tool's JSON Schema (required, unknown, primitive types);
5. the call, timed, with crashes turned into error results;
6. a `[:switchboard, :tool, :call]` telemetry event and one audit row, whatever the outcome.

The maintenance message, when set, is prepended to successful results. `tools/list` hides disabled
tools, and write tools in read-only mode.

### Controls cache

`Controls` keeps a `:persistent_term` snapshot of `global_controls` and `tool_controls`, so the hot
path never queries the database. Writes reload it and broadcast `:controls_changed` on the
`"controls"` topic; open LiveViews refresh (the maintenance banner, the admin page). Tests run with
`cache: false` so each sandbox sees only its own rows.

## Data model

| Table | Purpose |
|---|---|
| `users` | People who signed in with Forgejo: `forgejo_id`, `username`, `email`, `name`, `admin` (from `ADMIN_USERNAMES` at each sign-in), `locale` (`es`/`en`), `time_zone`, `theme`, `session_version` (bumped by "revoke all"). |
| `connections` | One row per person and system. `secret` is a `cloak_ecto` encrypted map (`{"token"}`, Rocket.Chat `{"token","user_id"}`, Forgejo `{"access_token","refresh_token"}`); `identity` is who the credential belongs to as the upstream reported it; `identity_matches` compares it with the person (email, case-insensitive; username when there's no email); `status` is `ok`, `untested`, `error` or `rejected`; `expires_at` is the Forgejo access token's expiry. |
| `personal_tokens` | `sb_...` tokens: SHA-256 `token_hash`, a 7-character `hint`, optional `expires_at`, `last_used_at`, `revoked_at`. |
| `oauth_clients` | DCR-registered clients and cached CIMD documents (24 h). |
| `oauth_codes` | Authorization codes (hashed, 60 s, single use; replay revokes the grant). |
| `oauth_grants` | One client connection for one person: the refresh-token family. |
| `oauth_tokens` | Access (1 h) and refresh (30 d, rotating) tokens, hashed. |
| `audit_events` | Append-only: `at`, `user_id`/`username` (no foreign key, so the trail outlives the account), `kind` (`mcp`/`web`), `action` (tool name or web action), client, redacted `args`, `outcome` (`ok`, `error`, `denied`, `rate_limited`, `disabled`), `error`, `duration_ms`, `result_bytes`, `upstreams`, `ip`. |
| `global_controls` | One row: `read_only`, `maintenance_message`. |
| `tool_controls` | Per-tool overrides: `enabled`, `rate_limit` (calls per person per minute). |
| `oban_jobs` | Oban. Today only the daily audit retention job (`Switchboard.Audit.Prune`). |

### Audit append-only

A trigger (`audit_events_append_only`) raises on every `UPDATE` and on `DELETE`, unless the
transaction set `switchboard.audit_prune = 'on'` with `SET LOCAL`. Only `Audit.prune/1` does that,
deleting rows older than `AUDIT_RETENTION_DAYS` (default 180).

Arguments are stored redacted (`Audit.redact/2`): values under credential-like keys (`token`,
`secret`, `password`, `api_key`, `authorization`, `credential`, `cookie`) and under the names a tool
returns from `sensitive_args/0` become `"[redacted]"`; strings are cut at 200 characters, lists
at 20 items, and anything over 4 KB is replaced by a note.

## Auth flows

### Sign in (browser)

1. `/auth/forgejo` stores a `state` and a PKCE verifier in the session and redirects to Forgejo's
   `/login/oauth/authorize` (confidential client, PKCE S256).
2. `/auth/forgejo/callback` checks the state, exchanges the code, reads `/api/v1/user`,
   `/api/v1/user/orgs` (and `/api/v1/user/teams` when `ALLOWED_FORGEJO_TEAMS` is set).
3. The person must be active and in an allowed org or team. The user row is upserted, the
   Forgejo token stored encrypted as the `forgejo` connection, and a fresh session started with
   `user_id` and `session_version`.

### MCP client (OAuth)

As in `docs/CLIENTS.md`: discovery (RFC 9728, RFC 8414), CIMD or DCR, authorization code with PKCE
and `resource`, consent (the page names the client, its redirect host, and warns that a DCR
client's name is unverified), `iss` in the response, hashed opaque tokens.

**Every refresh re-checks Forgejo.** Before rotating a refresh token, `Accounts.recheck/1` calls
Forgejo with the person's stored token. A deactivated account, a revoked Forgejo token, or leaving
the allowed orgs revokes every grant of that person; access tokens already issued die within the
hour. If Forgejo can't be reached the refresh goes ahead (fail open), and the next one checks again.

### Personal tokens

`Authorization: Bearer sb_...`. `MCPAuth` verifies the hash, the expiry and revocation, and builds
a scope with `via: :personal_token` and the token's name as the client name.

### Forgejo token refresh

Forgejo access tokens live an hour. `Connections.forgejo_token/1` returns the stored token, or
refreshes it under a row lock when less than two minutes remain (Forgejo rotates the refresh
token; the new pair is stored). A rejected refresh marks the connection `rejected`, which the
next sign-in repairs.

## Upstream adapters

Each implements `Switchboard.Upstream` (label, key link, minimum permissions, form fields and
`whoami/1`). `whoami/1` checks a credential and returns who it belongs to.

| System | Credential | Identity check | Notes |
|---|---|---|---|
| Forgejo | OAuth token from sign-in | `GET /api/v1/user` | Forgejo 16 doesn't enforce OAuth scopes (see SECURITY). |
| Plane 1.4 | Personal API key, `X-API-Key` | `GET /api/v1/users/me/` | Key page: `/<workspace>/settings/account/api-tokens`. |
| Argus | `argus_...` token, bearer | `GET /api/v1/me` (Markdown: `Email:`, `Name:`, `Role:`, `Teams:` lines) | Matched by email like the others. |
| Outline 1.x | API key, bearer | `POST /api/auth.info` | Key page: `/settings/api-and-apps`. |
| Rocket.Chat 8 | Personal access token + user id, `X-Auth-Token`/`X-User-Id` | `GET /api/v1/me` | Key page: `/account/tokens`. |

`Upstreams.request/3`: `Req` with options from config (`req_options`, so tests use `Req.Test`),
5 s connect and 10 s receive timeouts, no retries, no redirects, a 2 MB body cap (8 MB for Outline search, which retries oversized results with a smaller limit), and JSON decoded
only when the response says it is JSON. Every request runs under `Upstreams.Guard`, is noted for the
tool call's audit row, and emits `[:switchboard, :upstream, :request]` telemetry.

## The read path (milestone 3)

```
tool ──▶ API client (Plane, Forgejo, Argus, Outline, Releases)
           └─▶ Upstreams.request/3 ──▶ Guard (concurrency slot + circuit breaker) ──▶ Req
cross-system tool ──▶ FanOut.run/2 (one task per system, shared time budget) ──▶ the above
```

- **Credentials:** every read uses the caller's own credential (`Upstreams.credential/2`): the
  Forgejo sign-in token, or the person's linked key. The only service credential read is the
  releases feed. A missing or rejected credential becomes one line with the Connections link.
- **API clients** (`Switchboard.Plane`, `Switchboard.Forgejo`, `Switchboard.Argus`,
  `Switchboard.Outline`, `Switchboard.Releases`): thin, read-only, returning `{:ok, data}` or a
  reason that `Upstreams.problem/2` turns into a sentence. `Switchboard.Forgejo` can only send GET.
- **Guard** (`Switchboard.Upstreams.Guard`, one GenServer): per system, at most `max_concurrency`
  requests in flight (default 8, Plane 4) across everyone; extra callers queue up to
  `acquire_timeout` (3 s) and then get `:busy`. Slots are tied to the caller's pid, so a killed task
  releases its slot. Five consecutive failures (timeouts, transport errors, 5xx) open the breaker
  for 30 s: requests fail fast with `:circuit_open`; then one trial request decides. 4xx answers
  don't count. Config: `config :switchboard, Switchboard.Upstreams, guard: [...]`.
- **FanOut** (`Switchboard.FanOut.run/2`): runs `{key, system, fun}` entries in supervised tasks
  with one deadline (9 s for `my_work` and `task_status`); a task past it is killed and reported as
  `{:error, :timeout}`, a crash as `{:error, :crashed}`. Tools render what arrived and append a
  **Notes** list for the rest.
- **Untrusted content** (`Switchboard.Untrusted.wrap/3`): descriptions, comments, error titles and
  texts, wiki pages, CI logs and release highlights go inside
  `<untrusted source="..." ...>` blocks; tags inside the text are neutralised.
- **Output:** compact Markdown (`Switchboard.Markdown`): tables with escaped cells, absolute links,
  times in the person's time zone, capped at 12 000 characters (16 000 for `my_work`).
- **Cache** (`Switchboard.Cache`): every Plane GET is cached per key for 45 s (and `my_items` as a
  whole), projects, states, members and `users/me` for 10 minutes. People's Plane keys are shared
  with their other tools (about 60 requests a minute), so repeated `my_work` calls don't burn the
  budget. A Plane write drops that key's cached reads. A 429 says plainly that the key's rate limit
  is used up.

## The write path (milestone 4)

Writes go through the same `Tools.run/3` policy (kill switch, read-only mode, rate limit — 10 per
person per minute by default —, audit) and the same guard, with two extra rules:

- **Only the person's own credential.** `plane_comment`, `plane_set_state` (Plane key),
  `error_resolve`, `error_ignore` (Argus token), `docs_draft` (Outline key) and `send_message`
  (Rocket.Chat token + user id) refuse when it's missing. There is no fallback to a service
  credential anywhere; the policy-matrix test (`test/switchboard/write_tools_test.exs`) checks it
  for every write tool, together with read-only mode and the kill switches.
- **Confirmation:** every write tool is annotated `readOnlyHint: false` and its description tells
  the agent to show the exact change and get the user's OK first.

| Tool | Upstream call | Guards |
|---|---|---|
| `plane_comment` | `POST .../work-items/{id}/comments/` (`comment_html`, escaped) | ≤ 5 000 characters |
| `plane_set_state` | `PATCH .../work-items/{id}/` (`state`) | name checked against the project's states (case-insensitive); returns old → new; no-op when unchanged |
| `error_resolve`, `error_ignore` | `POST /api/v1/projects/{slug}/issues/{id}/resolve` / `ignore` | ignore only for errors that need no fix (description) |
| `docs_draft` | `POST /api/documents.create` with `publish: false` | refuses to report success if Outline says it was published |
| `send_message` | `rooms.info` + `subscriptions.getOne` (membership), `im.create` for `@user`, `chat.postMessage` | refuses `@all`, `@here`, `@everyone`, channels the person isn't in, > 4 000 characters; the text is redacted in the audit log |
| `notify_me` | the bot user: `users.info`, `im.create`, `chat.postMessage` | DM to the caller only; ≤ 1 000 characters; 30 per hour; mentions defused; notice line in the person's language |

### notify_me and the bot user

`notify_me` is the only tool that uses a service credential: an existing Rocket.Chat bot
user's personal access token (`ROCKETCHAT_BOT_USER_ID`, `ROCKETCHAT_BOT_TOKEN`). The recipient is
always the caller: the username of their linked Rocket.Chat key when it matched their email,
otherwise the Rocket.Chat user with their Forgejo username, accepted only if its display name is
their Forgejo name. Other automation may answer in that bot's DMs, so every notice ends with
"Automatic notice from Switchboard. Replies here aren't read." (or the Spanish version) and
contains no live @-mentions (a zero-width space follows every `@`).

### Upstream notes

- **Plane** (v1.4, one workspace, `PLANE_WORKSPACE`): no server-side assignee filter. `plane_my_items` reads the
  member projects ordered by state group (backlog, unstarted, started, completed, cancelled), keeps
  the person's items and stops at the first closed one (a page or two per project). `expand=state`
  returns the state object. The API key allows about 60 requests a minute, shared with anything
  else using it; a 429 becomes "rate limit reached".
- **Forgejo** (16.0.7): PR search through `/repos/issues/search?type=pulls`; CI from the combined
  commit status and Actions runs/jobs; job logs mark steps with `⭐ Run Main <step>` and the failing
  step ends with `⚙️ [runner]: exitcode 'N': failure`. `ci_failure` keeps the lines of the failing
  step before that marker (last 60), without timestamps, scrubbed of secrets.
- **Argus:** Markdown tables parsed into rows; issue text trimmed (the User, Request and
  breadcrumb noise dropped, capped at 15 000 characters). `my_work` reads the 6 projects with most unresolved issues and flags an error
  when its culprit matches a file the person changed in the window (path, path without extension,
  or dotted module name).
- **Outline:** `documents.search` and `documents.info`; relative document URLs are made absolute;
  `docs_read` pages the Markdown in 8 000-character pages.

## Releases

`Switchboard.Releases` is a behaviour with two adapters: `Releases.HTTP` (production) and
`Releases.Fake` (synthetic releases for development, since the feed is usually internal-only). The
feed is served by the release bot that posts release cards in Rocket.Chat:

`GET $RELEASES_URL/releases?repo=<name>&since=<ISO 8601>&limit=<1-200>` with
`Authorization: Bearer <RELEASES_TOKEN>`, typically on a Docker network shared with the bot. It answers
`{ "releases": [...] }`, newest first, kept 90 days; 404 without a token configured, 401 with a wrong
one.

```json
{
  "repo": "web", "name": "release-2026.11.23.1", "sha": "<40 hex>",
  "status": "success",
  "startedAt": "2026-11-23T16:02:11.000Z", "finishedAt": "2026-11-23T16:09:40.000Z",
  "actor": "bruno", "runUrl": "https://…", "cardUrl": "https://chat…/channel/…?msg=…",
  "previous": "release-2026.11.20.1", "commitCount": 2, "migrations": 1, "authors": ["ana"],
  "commits": ["<40 hex>", "…"],
  "highlights": ["Customers can export invoices (PROJ-120)"],
  "tasks": [{ "id": "PROJ-120", "url": "https://…/browse/PROJ-120/", "match": "mentioned",
              "commits": ["<40 hex>"], "evidence": null }],
  "health": "red", "watching": true,
  "argusIssues": [{ "id": "50", "title": "ZeroDivisionError: …", "url": "https://…",
                    "triageUrl": "https://chat…", "fromRelease": true }]
}
```

- `status`: `deploying`, `success`, `failure`, `cancelled` or `skipped`.
- `highlights`: `null` while being prepared, `[]` when nothing is visible to the business.
- `tasks[].match`: `mentioned` (a commit names the task) or `matched` (found from the changes;
  `evidence` says why).
- `health` (`green`, `yellow`, `red`): set for successful releases only; `watching` is true during
  the 24 h window.
- `argusIssues[].fromRelease`: the triage cited the release's commits or changed files.
- `authors` are Rocket.Chat usernames; `my_work` matches them against the person's Forgejo username
  and their linked Rocket.Chat username.

The releases feed is a service credential (`RELEASES_TOKEN`), read-only and the same for everyone;
it only serves what the release cards already show in Rocket.Chat.
