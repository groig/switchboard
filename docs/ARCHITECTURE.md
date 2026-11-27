# Architecture

```
agent ──Streamable HTTP + bearer──▶ Caddy ──▶ Switchboard (Phoenix)
                                               ├─ /mcp                       MCP endpoint (OAuth or sb_ token)
                                               ├─ /oauth/*, /.well-known/*   authorization server
                                               ├─ /auth/forgejo*             sign in with Forgejo
                                               ├─ /auth/github*              connect GitHub (OAuth App, optional)
                                               ├─ /hooks/forgejo             Forgejo webhook (HMAC; a hint for watches)
                                               ├─ web app (LiveView)         connections, clients, activity, watches, profile
                                               └─ /admin, /dev               private network only (proxy rule + ADMIN_NETWORKS)
              upstreams: Forgejo · Plane · Argus · Outline · Rocket.Chat · release bot (releases feed) · GitHub (optional)
```

## Layers

| Layer | Modules | Notes |
|---|---|---|
| MCP adapter | `Switchboard.MCP.Server` | The only module that references `anubis_mcp`. Lists tools per caller, forwards calls to `Tools.run/3`; registers workflows as prompts and forwards `prompts/get` to `Workflows.run/4`. |
| Tools | `Switchboard.Tool`, `Switchboard.Tools`, `Switchboard.Tools.*` | A behaviour plus a registry. `Tools.run/3` is the single policy point (below). |
| Upstreams | `Switchboard.Upstreams`, `Switchboard.Upstream`, `Switchboard.Upstreams.*` | One adapter per system. All HTTP goes through `Upstreams.request/3`. |
| Identity | `Switchboard.Accounts`, `Switchboard.Forgejo.Login`, `SwitchboardWeb.UserAuth` | Forgejo sign-in, membership checks, browser sessions. |
| Authorization server | `Switchboard.OAuth`, `Switchboard.OAuth.CIMD` | OAuth 2.1 for MCP clients (see `docs/CLIENTS.md`). |
| Credentials | `Switchboard.Connections`, `Switchboard.Vault` | Per-person upstream secrets, encrypted with `cloak_ecto`. |
| Personal tokens | `Switchboard.PersonalTokens` | `sb_...` bearer tokens for clients without OAuth. |
| Read path | `Switchboard.Plane`, `.Forgejo`, `.GitHub`, `.Argus`, `.Outline`, `.Releases`, `Switchboard.Repos`, `Switchboard.Upstreams.Guard`, `Switchboard.FanOut`, `Switchboard.Untrusted` | Read-only API clients, Forgejo/GitHub routing, per-upstream limits and breakers, concurrent fan-out (below). |
| Safety | `Switchboard.Audit`, `Switchboard.Controls`, `Switchboard.RateLimit` | Append-only audit, live kill switches and read-only mode, ETS token buckets. |
| Watches | `Switchboard.Watches`, `Switchboard.Watches.*` (Oban workers) | "DM me when this finishes" (below). |
| Workflows | `Switchboard.Workflow`, `Switchboard.Workflows`, `Switchboard.Workflows.*`, `Switchboard.Tools.Workflow` | Team workflows as MCP prompts (slash commands) and as the `workflow` tool (below). |
| Onboarding | `Switchboard.Onboarding`, `SwitchboardWeb.StartLive`, `SwitchboardWeb.Admin.OnboardingLive`, `Switchboard.Workflows.Help` | Get started page, the `help` workflow and the admin Onboarding view, all from existing records (below). |

### `Tools.run/3`

Every MCP tool call goes through it, in this order:

1. the tool exists and its kill switch is on (`Controls.tool_enabled?/1`);
2. read-only mode refuses tools whose annotations aren't `read_only`;
3. the per-person, per-tool token bucket (`RateLimit.take/3`, limit from `Controls.rate_limit/1`:
   60/min for reads, 10/min for writes by default, overridable per tool from `/admin`);
4. argument aliases (`aliases/0`, e.g. `identifier` → `id`) renamed to the real name when that
   one is absent and recorded in the audit row as `_aliases`, then validation against the tool's
   JSON Schema (required, unknown, primitive types). A refusal names the missing and unknown
   arguments and lists what the tool takes (type, one-line description, aliases) with an example
   call, so an agent fixes it in one retry;
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
| `connections` | One row per person and system. `secret` is a `cloak_ecto` encrypted map (`{"token"}`, Rocket.Chat `{"token","user_id"}`, Forgejo `{"access_token","refresh_token"}`, GitHub `{"access_token"}`); `identity` is who the credential belongs to as the upstream reported it; `identity_matches` compares it with the person (email, case-insensitive; username when there's no email); `status` is `ok`, `untested`, `error` or `rejected`; `expires_at` is the Forgejo access token's expiry. |
| `personal_tokens` | `sb_...` tokens: SHA-256 `token_hash`, a 7-character `hint`, optional `expires_at`, `last_used_at`, `revoked_at`. |
| `oauth_clients` | DCR-registered clients and cached CIMD documents (24 h). |
| `oauth_codes` | Authorization codes (hashed, 60 s, single use; replay revokes the grant). |
| `oauth_grants` | One client connection for one person: the refresh-token family. |
| `oauth_tokens` | Access (1 h) and refresh (30 d, rotating) tokens, hashed. |
| `audit_events` | Append-only: `at`, `user_id`/`username` (no foreign key, so the trail outlives the account), `kind` (`mcp`/`web`), `action` (tool name or web action), client, redacted `args`, `outcome` (`ok`, `error`, `denied`, `rate_limited`, `disabled`), `error`, `duration_ms`, `result_bytes`, `upstreams`, `ip`. |
| `global_controls` | One row: `read_only`, `maintenance_message`, `watches_paused`. |
| `tool_controls` | Per-tool overrides: `enabled`, `rate_limit` (calls per person per minute). |
| `watches` | One per watch: `user_id`, `kind` (`ci`/`task`/`release`), `target`, `subject` (lookup key), `options`, `status` (`active`, `fired`, `expired`, `cancelled`) with `end_reason` and `ended_at`, `expires_at`, `last_state` (what the last check saw: statuses, names, links; never message text), `notified_at`/`health_notified_at` (decided once), `deliveries` (per notice: `sending`, `sent`, `unsure`), `checks`, `last_checked_at`. |
| `oban_jobs` | Oban: the daily audit retention job (`Switchboard.Audit.Prune`) and the watch jobs (queue `watches`). |

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
| Plane 1.4 | Personal API key, `X-API-Key` | `GET /api/v1/users/me/` | Key page: `/settings/profile/api-tokens` (1.4 moved it out of the workspace; the old path redirects). |
| Argus | `argus_...` token, bearer | `GET /api/v1/me` (Markdown: `Email:`, `Name:`, `Role:`, `Teams:` lines) | Matched by email like the others. Key page: `/settings#api-tokens`. |
| Outline 1.x | API key, bearer | `POST /api/auth.info` | Key page: `/settings/api-and-access` (1.7 and later; `/settings/api-and-apps` from 0.84 to 1.6). |
| Rocket.Chat 8 | Personal access token + user id, `X-Auth-Token`/`X-User-Id` | `GET /api/v1/me` | Key page: `/account/tokens`. |
| GitHub (optional) | OAuth App token (`repo` scope), bearer; linked at `/auth/github`, revoked on disconnect | `GET /user` | Hidden without `GITHUB_CLIENT_ID`/`GITHUB_CLIENT_SECRET`; optional in onboarding. REST API version `2022-11-28`. |

Adapters may implement `enabled?/0` (hidden everywhere when false), `connect_path/0` (linked
through an OAuth flow, so the Connections page shows Connect instead of a key form) and
`optional?/0` (not counted as missing on Get started and in the admin view).

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

`notify_me` and watch notices are the only uses of a service credential besides the releases feed:
an existing Rocket.Chat bot user's personal access token (`ROCKETCHAT_BOT_USER_ID`, `ROCKETCHAT_BOT_TOKEN`). The recipient is
always the caller (for a watch notice, the watch's owner): the username of their linked Rocket.Chat key when it matched their email,
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
  Images in `description_html`/`comment_html` are `<image-component src="<asset uuid>">` (older
  content: a full URL or `<img>`); `Switchboard.Plane.Images` numbers them (description, then
  comments oldest first) for `plane_get_item`'s `[image N: …]` placeholders and `plane_get_image`.
  An image is `GET /api/v1/workspaces/{slug}/assets/{asset_id}/` (Plane 1.5+; 1.4 answers 500;
  403 without project membership), whose `asset_url` is a presigned URL on the Plane host fetched
  without the key. Not `/api/assets/v2/...` (session cookie only) nor `issue-attachments` (real
  attachments only from 1.5). A `plane_get_image` call costs up to three key requests (item and
  comments are usually cached from `plane_get_item`, the asset route) plus the keyless download.
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

## GitHub repositories

Some teams' repositories live on GitHub. `Switchboard.Repos` decides where a `repo` argument
lives and returns the read client for it; `Switchboard.GitHub` has `Switchboard.Forgejo`'s read
functions with the same names and answers in the same shapes, so `pr_status`, `ci_failure`,
`repo_search_prs`, `watch_ci` and the joins render one way.

- **Routing** (`Repos.resolve/2`): `owner/repo` is GitHub when `owner` is in `GITHUB_OWNERS`
  (case-insensitive) and GitHub is configured, Forgejo otherwise; a URL of either server
  (repository, pull request, run; the GitHub web or API host) goes by host and keeps the PR or
  run number; `github:owner/repo` and `forgejo:owner/repo` force one. Stored CI watch targets
  carry `github:` (a bare one is always Forgejo, so changing `GITHUB_OWNERS` doesn't move
  existing watches).
- **Connection:** per person, through Switchboard's OAuth App (`Switchboard.GitHub.Login`,
  `SwitchboardWeb.GitHubAuthController`): `/auth/github` stores a `state` and a PKCE verifier in
  the session and redirects to `/login/oauth/authorize` (`scope=repo`); the callback compares
  the state in constant time (single use), exchanges the code, reads `GET /user` and stores the
  token encrypted (`Connections.store_github/3`, identity is the person's by construction).
  Disconnect calls `DELETE /applications/{client_id}/grant` (as the app) before removing the row;
  if GitHub can't be reached the row is removed anyway and the page links the person's GitHub
  settings. A token can't be pasted.
- **Shapes:** search hits (`/search/issues`, `is:pr`, `author:@me`, `review-requested:@me`,
  `reviewed-by:@me`, `assignee:@me`, `updated:>=`, `repo:`/`user:`) get `repository.full_name`
  and `pull_request.merged`; reviews map `CHANGES_REQUESTED`/`COMMENTED`/`DISMISSED` onto
  Forgejo's states (the REST API has no review decision; the per-reviewer summary stands for it);
  mergeability comes from `mergeable_state` (clean, unstable, behind, dirty, blocked, draft,
  unknown while GitHub computes it); CI merges check runs (`/commits/{sha}/check-runs`) and legacy
  commit statuses (`/commits/{sha}/status`) into one combined status; Actions runs and jobs get
  Forgejo's single `status`, and a run's number is its id (as in the run URL). Everything
  normalized carries `"host" => "github"`.
- **CI logs:** `GET /actions/jobs/{id}/logs` answers a redirect to a short-lived download URL,
  fetched without the token (http(s), no credentials in the URL, 4 MB cap). GitHub logs mark
  steps with `##[group]Run <command>` and fail with `##[error]Process completed with exit code N.`;
  `GitHub.failure_tail/2` keeps the failing step's lines (last 60, earlier `##[error]` lines
  included), strips timestamps and group markers and scrubs secrets as for Forgejo. The step name
  comes from the jobs API (the failed step), so CI watch notices don't download the log.
- **Rate limits:** each token has GitHub's own budget (5 000 requests an hour, search 30 a
  minute), shared with the person's other tools. Every GET sends the stored ETag (a `304` costs
  nothing) and reuses the cached body (10 minutes, per token). A `403`/`429` with
  `X-RateLimit-Remaining: 0` or `Retry-After` makes that token fail fast until the reset, without
  asking GitHub, and the message says when it resets. SAML SSO enforcement (`X-GitHub-SSO`) links
  the authorization page.
- **Joins:** `my_work`, `task_status` and the workflow prefetches (`Facts.my_prs`,
  `review_requests`, `pr_activity`) search both hosts (`Repos.search_all/2`, concurrently) for
  people who connected GitHub, limited to `GITHUB_OWNERS`. A failing host becomes a note, the
  other still renders; `FanOut` entries name both systems for the audit row. Task ids are
  matched in titles and bodies as on Forgejo. `my_work` doesn't match errors against GitHub
  commits (that still reads Forgejo only), and `release` reads only the releases feed.
- **Errors:** a Forgejo 404/400/422 for a named repo says it isn't on Forgejo and, when GitHub is
  configured, to use `github:owner/repo` or ask the admin to add the owner to `GITHUB_OWNERS`; a
  GitHub 403/404 (or search's 422) for a repo says the organization may need to approve the
  Switchboard app, with the person's app settings link; a 404 inside a visible repo (a PR, a run)
  is just "not found". A missing GitHub connection links its row on Connections and suggests the
  `help` workflow. Generally, a 4xx now reads as "refused the request: something it names
  doesn't exist or isn't valid", not as an outage.
- **CI watches** on GitHub are polled with the same backoff (1 to 5 minutes); there is no GitHub
  webhook, and Forgejo webhook hints only match Forgejo watches.

## Rocket.Chat reads (milestone 5)

`chat_inbox` and `chat_read` read as the person (their linked token), GET only.

- **Inbox:** `subscriptions.get` and `rooms.get`, both with `updatedSince` = the window (default 7
  days), cached 30 s per key. A DM (1:1 or group, `t: d`) is waiting when its room's
  `lastMessage` is from someone else and inside the window; unread (`unread > 0`) or read but
  not answered. Left out: the person's own last message, the Switchboard bot's DMs (its user id
  in `uids` or as sender), integration messages (`bot` field), bot accounts (`users.info` `type`
  `bot`/`app`, at most 5 checks a call, cached a day; roles are admin-only), hidden
  (`open: false`) and muted (`disableNotifications`) rooms unless `include_muted`. Oldest first.
  `mentions`: up to 3 channels with `userMentions > 0`, `chat.getMentionedMessages` (3 each).
  `threads`: up to 3 ids from `tunread`, the latest reply of each (`chat.getThreadMessages`).
  `lastMessage` ignores thread replies, so threads only show up there.
  **Known limitation:** a regular user only sees a user's `type`, not their roles, so a bot
  account created with type `user` (e.g. an admin-made user given the `bot` role) is treated as a
  person and its DMs can appear in the inbox. There is deliberately no ignore list.
- **Read:** `@username` (`im.messages`, which never creates a DM), `#channel` (`rooms.info`),
  a permalink of the configured host, or a room id; every room is checked with
  `subscriptions.getOne` (membership, as `send_message` does) before `im/channels/groups.history`
  (`showThreadMessages=false`, `latest` for paging). Threads: `chat.getMessage` (parent),
  membership, `chat.getThreadMessages`.
- **Never marked read:** none of these change read state (only `subscriptions.read`/`unread`,
  `chat.readThread` and the web client's DDP methods do). A test asserts every call is a GET to
  none of those endpoints.
- **Rate limits:** Rocket.Chat 8.x limits each REST route to 10 calls a minute per *client IP*
  (`API_Enable_Rate_Limiter_Limit_Calls_Default`/`_Time_Default`), so all of Switchboard shares one
  bucket per route; the bot role bypasses it (`api-bypass-rate-limit`). Personal calls spend a
  per-route budget in `Switchboard.RocketChat` and fail fast past it. The budget is
  `ROCKETCHAT_ROUTE_BUDGET` (calls a minute per route, all people together, per node; default 8,
  under Rocket.Chat's default 10). Keep it a little below the server's
  `API_Enable_Rate_Limiter_Limit_Calls_Default`: when the server allows 60 a minute, set about
  50. An inbox costs 2 calls, plus at most 5 + 3 + 3.

## Watches (milestone 5)

"DM me in Rocket.Chat when this finishes": `watch_ci`, `watch_task`, `watch_release`,
`list_watches`, `cancel_watch`, and `/watches` in the web app.

```
watch_* ──▶ watches row (+ first CiPoll job) ──▶ Oban:
  CiPoll (per CI watch, 1 → 5 min backoff)  ◀── Hint ◀── POST /hooks/forgejo (HMAC)
  Sweep (cron, every minute, one node): expire · recover CI jobs · releases feed once · queue TaskPoll
  TaskPoll (per person, every 5 min, their Plane key)
        └─ decide: UPDATE … WHERE status='active' AND notified_at IS NULL  +  insert Deliver (one transaction)
  Deliver (unique per watch+notice) ─ claim deliveries[notice] ─▶ RocketChat.deliver (bot user) ─▶ owner
```

**Decision: Postgres + Oban** (already a dependency) rather than in-memory timers. Watches survive
restarts and deploys (rows plus persisted jobs; Lifeline rescues orphans; the sweep re-creates a
missing CI job), Oban cron runs on one node, and the database is the only place that decides a
notice. Cost: one job per CI watch and a one-minute sweep, negligible at a few hundred watches.

- **Lifetime:** 24 h by default, up to 7 days (`hours`); a release waiting for health stays up to
  26 h after it finished. A watch that runs out of time expires quietly (`timed_out`, no DM); it
  still shows as expired in `list_watches` and on `/watches`. Each person has at most 20 active
  watches (`:max_active`); the same thing can't be watched twice.
- **Creation checks** with the person's own credentials: the Forgejo repo and PR/branch/run are
  visible (a CI run that already finished is answered instead of watched), the Plane item exists,
  the release repo is in the feed; and Switchboard knows the person's Rocket.Chat user.
- **CI:** for a PR or branch, every run of the head commit counts (all workflows); the watch is
  done when all runs are, `failure` if any failed. `next_run` counts only runs newer than the
  newest run at creation. The notice has the result, the run link and the failed job and step
  (parsed as `ci_failure` does; no log text). `only_on_failure` ends quietly on success.
- **Tasks:** one `Plane.item` read per watch every 5 minutes, one job per person so their watches
  share a pass (≤ 4 requests a minute with 20 watches, inside the ~60 a minute of their key;
  reads are cached). `until`: `any_change` (state change or shipped), `done` (completed or
  cancelled), `released` (the feed only; no Plane polling).
- **Releases:** the sweep reads the feed once for everyone. The next release is the oldest one not
  finished at creation that reaches `success`, `failure` or `cancelled` (`skipped` doesn't count).
  The notice has the name, status, run link and highlights (quoted, mentions defused). `health`
  adds a second notice when the 24 h window ends (`watching: false`, or 26 h): green/yellow/red
  and the Argus issues marked `fromRelease`.
- **No double notices:** the decision is a conditional update in the same transaction as the
  insert of a `Deliver` job that is unique per watch and notice for good; `Deliver` claims the
  notice in `deliveries` before calling Rocket.Chat and releases the claim only when the post
  certainly failed (`{:not_sent, _}`); a timeout on the post keeps it (`unsure`). A restart, a
  redeploy, a retried job or a second node can't send the same notice twice; the trade-off is that
  a crash mid-post can lose one.
- **Notices:** `RocketChat.deliver/2` as the bot user, to the owner only (the recipient rule of
  `notify_me`), in their `locale`, with mentions defused, the automatic-notice footer and a link to
  `/watches`. At most one notice per watch (the result, or the final "stopped" one) plus the
  health follow-up, and at most 30 watch notices per person an hour (more wait).
- **Watches that can't work any more** expire with one final notice explaining why: the owner's
  Forgejo or Plane connection is gone (`connection_missing`) or rejected (`connection_rejected`),
  or they lost access to the repo or item (`access_lost`: 403/404 with their token). These are
  the only reasons that send a final DM.
- **Pause:** `watches_paused` in the global controls (admin, audited): no new watches, no checks,
  notices wait. Each tool also has its own kill switch.

### The Forgejo webhook

`POST /hooks/forgejo` is a plug before `Plug.Parsers` (it needs the raw body). It answers 503
without `FORGEJO_WEBHOOK_SECRET`, 415 for anything but `application/json`, 413 over 1 MB, 401
unless `X-Forgejo-Signature` is the hex HMAC-SHA256 of the body (constant-time compare), and 202
otherwise, queuing a `Watches.Hint` for `run.repository.full_name`.

**Events (checked in the Forgejo source, v12 to v16):** Forgejo sends `action_run_success` and
`action_run_failure` (the latter also for cancelled and skipped runs) once per run, when it
reaches a final state, with an `ActionPayload` (`action`, `run` with `repository`, `commit_sha`,
`status`, `html_url`). `action_run_recover` exists but is never sent on 13–16 (its "previous run"
lookup is a stub). Forgejo has **no commit `status` webhook event** at all (Gitea has one). There
are no `workflow_run`/`workflow_job` events before v17, which adds `workflow_run_*` (also
accepted). So Switchboard uses the two "Action Run" events.

**A webhook is only a hint.** The hint moves the matching CI watches' next check to now (skipping
watches checked in the last 10 s); the check reads Forgejo again with the owner's own token. A
forged, stale or replayed webhook can at most cause an early check; it can't send a notice or
reveal a repo. Without the webhook, polling alone works (1 to 5 minutes later).

## Workflows (milestone 6)

Team workflows (`standup`, `next`, `inbox`, `pickup`, `triage`, `handoff`) chain several tools
into one command. Each is a `Switchboard.Workflow` module; `docs/TOOLS.md` lists what each one
prefetches and which writes it may propose.

```
Claude Code: /mcp__switchboard__pickup DEMO-12 ──prompts/get──▶ MCP.Server.handle_prompt_get ─┐
Codex (no prompts): "let's pick up DEMO-12" ──tools/call workflow──▶ Tools.run ─▶ Tools.Workflow ┤
                                                                                                ▼
Workflows.run/4: kill switch (workflow:<name>) · rate limit · argument checks · audit row
   └─▶ Pickup.build/3 ──▶ Facts.gather (FanOut, 12 s budget, caller's own credentials)
                            ├─ tool sections: PlaneGetItem, TaskStatus, DocsSearch (their kill switches apply)
                            └─ own reads: Argus issues mentioning the task
   └─▶ frame: header · numbered steps · rules (proposable writes, untrusted data, language) · Facts · Notes
```

- **One text, two ways.** The prompt's single user message and the `workflow` tool's result are
  the same text (a test compares them). Codex doesn't list prompts (`docs/CLIENTS.md`), so the
  server instructions name the workflows and tell the agent to use the tool when the user asks in
  plain words.
- **Prompt registration.** anubis has no per-request filter for prompts, so `MCP.Server.init/2`
  puts the enabled workflows on the frame: on every request in the 2026-07-28 era, once per
  session in the 2025-06-18 era (a workflow switched off mid-session stays listed there, and
  `Workflows.run/4` refuses it). Prompt arguments go through `validate_input: &{:ok, &1}`, as tool
  arguments do; `Workflows` checks them (known names, strings, required ones, ≤ 300 characters,
  then per workflow: `PROJ-123`, `#channel`/`@user`, an Argus issue URL or `project/id`).
- **Policy.** `Workflows.run/4` mirrors `Tools.run/3`: a kill switch and a rate limit per
  workflow, stored in `tool_controls` under `workflow:<name>` (10 runs per person per minute by
  default; the admin Controls page lists them under Workflows), one audit row with action
  `workflow:<name>` and `args.via` = `prompt` or `tool`, telemetry
  `[:switchboard, :workflow, :run]`, crashes turned into an error. Through the `workflow` tool,
  `Tools.run/3` applies the tool's own kill switch, limit and schema first and then leaves the
  audit row to `Workflows.run/4` (a process flag), so a run is audited once.
- **Never writes.** A workflow only reads. Its text lists the writes the agent may *propose*,
  only those whose tools are available right now (none in read-only mode, none that are switched
  off), and requires one confirmation per write of the exact text and destination.
- **Prefetch.** `Switchboard.Workflows.Facts` holds the shared reads: open and recently updated
  Plane items, the person's pull requests with CI and reviews, review requests, PR activity since
  a date, errors pointing at their changes (`my_work`'s culprit match plus the release triage),
  the DM count, watches that fired. Sections that reuse a tool's output call the tool module
  directly (not `Tools.run/3`, which would audit and rate-limit each one) and honour its kill
  switch. A failed or slow system becomes a note under **Notes**; the rest still renders.
- **Local code.** The steps lean on the agent running in the developer's checkout: `git log`
  for the standup, the code and history for `pickup` and `triage`, the diff for `handoff`.
- **Language.** Instructions to the agent are English; drafts for colleagues (standup, QA
  message, DM replies) are asked for in the person's `locale`.
- **Costs.** A `standup` reads each member Plane project once more (recently updated items, one
  page) on top of the cached `my_items`; `next` and `inbox` reuse `my_items` and the 30 s inbox
  listing (two Rocket.Chat calls, plus at most 11 for mentions, threads and bot checks); `pickup`
  and `handoff` read one item (cached) and its project. The `next` DM count costs no extra
  Rocket.Chat call beyond the listing.
- **Completion.** `completion/complete` for a `task` argument returns the person's open Plane
  items (from the cached `my_items`; 60 a minute per person). Claude Code 2.1.325 doesn't ask
  for completions.
- **Limits of the data.** Plane's API has no per-person activity feed or @-mention list, so
  "items I changed" means items assigned to or created by the person that were updated in the
  window, and `inbox` says Plane mentions may be missing. `triage` finds the repository through the
  release that first listed the issue (its run URL); without one, the agent uses local history.

## Onboarding (milestone 7)

One guided path from signing in to "my agent just did something useful", in the app (`/start`)
and in the agent (the `help` workflow). Nothing is tracked separately: `Switchboard.Onboarding`
derives every state from records that already exist.

| Step | Done when | Source |
|---|---|---|
| Connect your agent | any MCP call by the person (shows the client and when) | latest `audit_events` row with `kind = 'mcp'` |
| Link your accounts | every system is linked and working | `connections` (`rejected` or someone else's key is an error; `untested` counts as linked) |
| Try these | 3 of the 12 prompts tried | distinct `action` of their successful MCP rows; each prompt lists the tools or `workflow:<name>` that tick it |
| Commands | any workflow run | the same rows (`workflow:<name>`) |

- **Landing.** `UserAuth.signed_in_path/1` sends a person to `/start` after sign-in (and from
  `/`) until they have one successful MCP call, to Connections after that; a stored `return_to`
  (the OAuth consent screen) still wins. The page stays in the sidebar.
- **Live.** `Audit` broadcasts each new row on `audit:user:<id>` (kind, action and outcome only);
  the page reloads its state on each one, so a prompt ticks off while the agent runs it.
- **Personalized prompts.** After the page connects, `Onboarding.samples/2` reads one of the
  person's own open Plane items (the cached `my_items`) and the newest unresolved issue of their
  busiest Argus project (two calls), with their own keys, in a `FanOut` with an 8 s budget, cached
  5 minutes per person. Only identifiers are shown (`PROJ-12`, `project/7`). Anything missing,
  failing or slow falls back to `<task>`/`<error>`; a skeleton shows while it loads.
- **Greyed out.** A prompt whose systems aren't linked and working can't be copied and links to
  that system's row on Connections (`/connections#connection-<system>`), the same anchor the tools'
  "not connected" lines now use (`Upstreams.connection_url/1`).
- **Commands.** The Commands section and the `help` command table are generated from the workflow
  registry: each workflow's `purpose/0` (a Gettext msgid, so the page is translated), its
  arguments and `example/0` (`says` is the plain-words version for Codex).
- **`help`.** A seventh workflow (prompt and `workflow` tool, same policy). It makes no upstream
  call: the person, their accounts with links to fix them, the commands written for the calling
  client (`Onboarding.client_kind/1` from the CIMD client id or name), and three suggestions from
  the checklist (linked and untried first), personalized only from the cache. The server
  instructions tell the agent to suggest it on a missing connection or when the user seems new.
- **Admin view.** `/admin/onboarding` (admin and tailnet only, read-only): per person the agent
  (client, when, whether a call succeeded), accounts linked, prompts tried and last activity, in
  four queries.

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
