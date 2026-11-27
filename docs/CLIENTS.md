# MCP clients: what they do and what Switchboard relies on

Findings from testing Switchboard with real clients (Claude Code 2.1.325 and Codex 0.170.0, through
Caddy 2.11). They explain several rules in `AGENTS.md`.

| | Claude Code | Codex |
|---|---|---|
| Client registration | **CIMD** `https://claude.ai/oauth/claude-code-client-metadata` | **CIMD** `https://chatgpt.com/oauth/codex/client.json` |
| MCP protocol version | **2026-07-28** (stateless: `server/discover`, no `initialize`) | **2025-06-18** (`initialize` + session) |
| Redirect URI | `http://localhost:<random>/callback` | `http://127.0.0.1:<random>/callback` |
| Scope requested | `mcp` (from `scopes_supported`) | `mcp` |
| `resource` parameter (RFC 8707) | sent | sent |

Dynamic client registration (RFC 7591) also works; neither real client needs it by default.

## Codex with dynamic client registration (2026-11-27)

A pilot user approved the consent screen about ten times over two hours, with eight DCR-registered
Codex clients, before any MCP call succeeded; it worked once Codex used its CIMD URL. The audit
log had no trace of why, because the token endpoint wasn't audited (it is now, see
`docs/ARCHITECTURE.md`, "OAuth audit").

Reproduced against local dev with Codex 0.172.0, `codex mcp login switchboard --no-browser
--oauth-client-registration dcr` (consent driven by hand), then a Codex session after expiring
the access token:

| Step | What Codex sent | Result |
|---|---|---|
| Discovery | `GET /mcp` (401), protected resource metadata, authorization server metadata | ok |
| Registration | `client_name: "Codex"`, `redirect_uris: ["http://127.0.0.1:<port>/callback"]` (the port of that login), `grant_types` code + refresh, `response_types: ["code"]`, `application_type: "native"`, `scope: "mcp"`, auth method `none` | 201, a new client per login |
| Authorize | `response_type=code`, PKCE S256, `redirect_uri` as registered, `scope=mcp`, `resource=<origin>/mcp` | consent, then the loopback callback |
| Token | code exchange | 200 |
| Next session | the expired access token refreshed, then `initialize` and calls | 200 |

So the DCR path works end to end with this Codex, including refresh. With `auto` (the default)
Codex 0.172 uses CIMD whenever the server advertises it, as Switchboard does; the pilot's DCR
clients therefore came from an older Codex or a forced registration mode. Checked and ruled out
on Switchboard's side: loopback port matching (any port, same host and path), PKCE, the
`resource` check (sent at authorize; optional at the token endpoint, trailing slash accepted),
code lifetime (60 s, exchanged within a second), access and refresh token lifetimes, the CSP
`form-action` for the loopback redirect, and refresh for DCR clients.

Two things are now handled more forgivingly: a public client may send `client_id` as HTTP Basic
credentials with an empty password, and the Clients page collapses a client's repeated
registrations so the stale ones can be removed. `test/switchboard_web/controllers/oauth_codex_flow_test.exs`
replays Codex's requests. Without `--no-browser`, Codex waits for the browser to reach its
loopback callback; if Codex runs on another machine (SSH, a container), the browser's redirect to
`127.0.0.1:<port>` never reaches it, which looks exactly like repeated approvals with no token
request. The `oauth.approved` rows without a following `oauth.token_issued` or `oauth.token_failed`
now show that case.

## Protocol versions

- **2026-07-28** removes the handshake: every request carries
  `_meta.io.modelcontextprotocol/protocolVersion` (and `clientCapabilities`), plus the
  `Mcp-Protocol-Version`, `Mcp-Method` and, for `tools/call`, `Mcp-Name` headers. It deprecates DCR
  in favour of CIMD and adds RFC 9207 `iss` validation.
- **2025-06-18** uses `initialize` and an `Mcp-Session-Id`.
- `anubis_mcp` serves both from one Plug. The server instructions reach both: in the `initialize`
  result and in `server/discover`.
- Because the new era is stateless, the server's `init/2` runs on every request and a session holds
  nothing between calls. Identity always comes from the request's bearer token.

## MCP prompts (team workflows)

Tested on 2026-11-26 against local dev, through a proxy that logged JSON-RPC method names, with
Claude Code 2.1.325 and Codex 0.170.0.

| | Claude Code | Codex |
|---|---|---|
| Lists prompts | yes: `prompts/list` at startup, after `server/discover` | **no**: only `initialize`, `notifications/initialized`, `tools/list` (exec and TUI) |
| Slash command | `/mcp__<server>__<prompt>`, e.g. `/mcp__switchboard__standup` | none for MCP prompts (its `/` menu has built-ins and local custom prompts) |
| Arguments | positional, space-separated, in the declared order: `/mcp__switchboard__handoff DEMO-12 #qa` → `task`, `channel` | – |
| Argument completion | **no**: the menu shows `[task]` as a hint, but no `completion/complete` is ever sent | – |
| Errors | a `prompts/get` error is shown as `ProtocolError: <message>`, without a model turn; a missing required argument is caught by the client (`Missing required argument: task. Usage: ...`) | – |
| How to run a workflow | the slash command, or plain words | plain words: "do my standup" led Codex to `tools/call workflow` with `name: standup` |

- The `/` menu shows each prompt as `/mcp__switchboard__pickup (MCP)` with its description and
  `(arguments: task)`, so the description must say what the command does in one line and names
  must be short (the prefix is long already).
- `claude -p "/mcp__switchboard__next"` works too (print mode expands the prompt).
- The prompt's text is inserted as a user message and the model follows it.
- Values with spaces in arguments are untested; no workflow needs them (task ids, `#channel`,
  issue URLs).
- Because Codex never lists prompts, every workflow is also the `workflow` tool, and the server
  instructions list the workflows. Switchboard still answers `completion/complete` for `task`
  (the person's open Plane items), for clients that ask.

## Quirks

1. **Portless loopback redirect URIs.** Both clients' CIMD documents list
   `http://localhost/callback` and `http://127.0.0.1/callback` without a port, then use a random
   port. RFC 8252 port-agnostic matching for loopback is required, not optional.
2. **anubis drops tool arguments** when a tool has no `validate_input`: the handler gets `%{}`.
   The adapter passes `&{:ok, &1}` and validation lives in `Switchboard.Tools`.
3. **`codex mcp add` starts the OAuth login right away** and opens the browser.
4. **`claude mcp login` needs a TTY** and opens the browser through `xdg-open` (it ignores
   `$BROWSER`).
5. A POST that accepts SSE gets its JSON-RPC response as a single SSE event once the tool finishes.
   Progress notifications during a long call are untested; v1 tools answer within the request.

## Behind Caddy (streaming)

- A Caddy site with `encode zstd gzip` compresses `text/event-stream` too, but still flushes every
  event: keepalives arrived on the 15 s tick with and without compression. anubis sends
  `X-Accel-Buffering: no` and `Cache-Control: no-cache`. No special rule is needed; just don't add
  response buffering.
- On a session whose earlier GET stream was cut off, a new GET stream showed two keepalives per tick
  (a fresh session shows one). Harmless (they are comments), but worth watching once the server
  pushes events.
- Set `PUBLIC_URL` to the URL clients use, so the OAuth issuer and resource match.
