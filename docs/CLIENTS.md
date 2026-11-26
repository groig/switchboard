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

Dynamic client registration (RFC 7591) also works (tested with a scripted client); neither real
client needed it.

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
