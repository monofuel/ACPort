# ACPort

A threaded Nim library for [Agent Client Protocol](https://agentclientprotocol.com/)
clients and agents. A sibling to [MCPort](https://github.com/monofuel/MCPort).

## ACPort 1.2

Supports core **ACP v1 over Linux stdio**, with both client and agent/server APIs:

- Version and capability negotiation, plus agent-managed authentication.
- New sessions, multiple turns, concurrent sessions, and `session/load` with history replay.
- Configuration catalogs with flat/grouped selects, negotiated booleans, and live updates.
- Explicit legacy session modes, alongside `session/set_config_option`.
- Paginated session listing, resume without history replay, and cooperative session closure.
- Streamed messages, reasoning, tool reports, rich content, text diffs, and plans.
- Permission requests with explicit approval, rejection, or cancellation.
- Cooperative session cancellation and request deadlines.
- Unknown update payloads and `_meta` preservation for forwarding.
- Bidirectional custom request/notification hooks and extension capability metadata.
- Typed command catalogs and absolute usage/cost snapshots.
- Opt-in form and URL elicitation, with cancellation and correlated URL completion.

The implementation targets the stable v1 schema at
[`c392d7e9d1de01337b749c0070929933e9f6f09f`](https://github.com/agentclientprotocol/agent-client-protocol/blob/c392d7e9d1de01337b749c0070929933e9f6f09f/schema/v1/schema.json).
The package version `1.2.0` and the wire protocol version `1` are separate.

The library uses threads, locks, and condition variables, without asyncdispatch.
Its only package dependency is [jsony](https://github.com/treeform/jsony), pinned
in `nimby.lock`. HTTP libraries and MCPort are not required.

HTTP/WebSocket transport, ACP v2, client filesystem and terminal execution,
persisted session deletion, and vendor-specific implementations are outside 1.2.
Unknown update variants remain available as raw JSON.
Client filesystem, terminal, and other unsupported capabilities are not advertised.
An agent advertises lifecycle capabilities only when the corresponding handlers exist.

## Development

Requires Linux, Nim 2.0 or newer, Nimby 0.2.3 or newer, and Make.
The release is tested using Nim 2.2.4 with ARC and ORC.
Use Nimby for dependency management; the `.nimble` file supplies package metadata.

Create a workspace in the parent of the checkout:

```sh
mkdir acport-workspace
cd acport-workspace
nimby create
git clone https://github.com/monofuel/ACPort.git
cd ACPort
make setup
make check
make test-arc
make test-orc
make examples
```

For an existing checkout, run `nimby create` from its parent first. Project
settings live in `config.nims`; Nimby manages the workspace's `nim.cfg`.
Nim compilation automatically enables threads and includes `src` on the import path.

## Client

```nim
import acport

proc showUpdate(update: SessionUpdate, userData: pointer) {.gcsafe.} =
  ## Display streamed agent text from the callback thread.
  if update.kind == agentMessageChunk and update.content.kind == textContent:
    stdout.write(update.content.text)
    stdout.flushFile()

proc main() =
  ## Run one prompt against an installed ACP agent.
  let client = newAcpClient("my-client", "1.0", ClientHandlers(onUpdate: showUpdate))
  defer: client.close()
  client.connect("codex-acp")
  discard client.initialize()
  let session = client.newSession("/absolute/project/path")
  discard session.prompt("Summarize the project.")

main()
```

`connect` accepts an argument array, a child working directory, environment
overrides, and a request-worker count (default 16). It does not invoke a shell or
change the parent's working directory. Child pipes are close-on-exec.

`prompt` blocks until the v1 completion response, while background threads deliver
updates and answer permission requests. For application-controlled concurrency:

```nim
var turn = session.startPrompt(@[textBlock("Inspect the project.")])
# Other application threads may work or call session.cancel().
let completion = turn.waitForPrompt()
```

`turn.isReady()` polls without waiting, cancelling, or consuming the handle. It
becomes true when `waitForPrompt()` can settle with a response or terminal error,
including RPC/protocol errors, disconnect without a completion, and client close.
Readiness for a response includes delivery of preceding update callbacks. If a
response arrived just before disconnect, those callbacks still finish first.
`isReady()` reports readiness, not success: consume the handle once with
`waitForPrompt()` to retrieve its response or raise its error. Poll and consume
from the handle's owning thread; a consumed or empty handle raises `ValueError`.

Each connection supports multiple sessions, with one active prompt per session.
`PromptHandle` is a move-only value: consume every handle exactly once, even after
closing the client. Updates received before a response are delivered before the
corresponding blocking call returns. Updates outside turns are delivered too.

Call `loadSession(sessionId, cwd, mcpServers)` on a newly connected client to
continue stored conversations. It checks the peer's capability and finishes only
after history replay callbacks have run. The agent, rather than ACPort, stores
the conversation. Session working directories must be absolute. MCP configuration
is carried as JSON; applications are responsible for making the actual connections.

Authentication methods are returned by `initialize`. Existing Codex login state
can be used by its adapter. `authenticate(methodId)` invokes an advertised
agent-managed flow; ACPort does not launch interactive terminal authentication.
`authenticate(methodId, timeoutMs = 0, meta = payload)` optionally forwards an
opaque JSON payload as `_meta`, for agent-specific headless authentication. The
agent's `AuthenticateRequest.meta` receives it unchanged. Omitting `meta` keeps
the existing request shape. Credential interpretation belongs to the agent.
No browser, login, retry, or reconnect is initiated automatically.

## Session configuration and lifecycle

`session.getConfigOptions()` returns the latest owned configuration snapshot.
Discover identifiers and values from that catalog; categories such as `model` and
`thought_level` are optional hints. Select choices may be flat (`options`) or
grouped (`groups`). Use `setConfigOption(id, value)` with a string or boolean.
Its response replaces the complete catalog: changing a model can also change
the available reasoning levels. Unknown option types retain their raw payload
for forwarding, but cannot be set through the typed API.

Boolean options are negotiated through the client's
`session.configOptions.boolean` capability. ACPort clients declare support, and
ACPort agents omit boolean controls when a peer has not negotiated them.

`getModes()` returns optional legacy mode state; `setMode(id)` invokes the legacy
endpoint explicitly. ACPort does not guess a configuration identifier for modes
or automatically retry using a different endpoint. `getSessionInfo()` returns
known cwd, title and timestamp metadata. These getters read shared connection
state and return independent snapshots. Copies of an `AcpSession` share the same
live state. The existing `session.state` remains the initial response snapshot.

Configuration, mode and metadata notifications update the cache in wire order
before application callbacks run. Use `parseConfigOptionUpdate`,
`parseCurrentModeUpdate`, or `parseSessionInfoUpdate` to decode them from an
`unknownUpdate` callback. The 1.0 `UpdateKind` enum is unchanged. An omitted title
or timestamp leaves it unchanged; explicit null clears it. Late responses after
a request deadline still update live state.

`client.listSessions(cwd = some(path), cursor = some(token))` returns exactly one
page with an optional `nextCursor`; both arguments are optional. Listing does not
activate stored sessions. `resumeSession(id, cwd)` restores a conversation without
replaying its messages; status and metadata updates may still arrive. Use
`loadSession` when history replay is needed. These optional methods check the
peer's advertised capabilities before sending requests.

`session.closeSession()` cancels ongoing work and releases that session's active
resources while keeping the connection and saved history. Repeated closure is
harmless. Copies of a closed session reject new prompts until an explicit load
or resume reopens it. A close deadline leaves the session locally closing; retry
close or explicitly load/resume to recover. ACPort never deletes persisted history.

## Agent/server

Provide an `AgentHandlers` record to `newAcpAgent`, then call `runStdioAgent`.
The required handlers are `onNewSession` and `onPrompt`; authentication, loading,
and cancellation hooks are optional. See [examples/agent.nim](examples/agent.nim)
for a complete in-memory echo agent.

Session handlers return `SessionResponse` with an application-supplied unique ID.
Load handlers restore application state and send replay updates before returning.
Optional `onResumeSession`, `onListSessions`, `onCloseSession`,
`onSetConfigOption`, and `onSetMode` handlers implement the additional endpoints.
Resume handlers restore state without replay. Configuration handlers return the
full authoritative catalog. Close signals cancellation, settles queued prompts,
and waits for running handlers before invoking `onCloseSession` for application
cleanup and acknowledging closure. Cleanup must retain whatever saved history
the application needs for future load/resume.
Prompt handlers receive typed content and return `PromptResponse` with a stop
reason. A request context provides:

- `sendUpdate`: publish structured messages, tools, diffs, or plans.
- `requestPermission`: wait for the client's decision without blocking the reader.
- `isCancelled`: check cooperative cancellation, including connection shutdown.

Agents supply their own tools, MCP connections, LLM integration, authentication
policy, and persistence. ACPort does not automatically execute reported tool calls.

## Extensions and typed event state

`client.requestExtension(methodName, params, timeoutMs)` makes a blocking custom
request; `client.notifyExtension(methodName, params)` sends a notification. The
same helpers on `RequestContext` support the agent direction and parent-request
cancellation. Supply the complete wire method name, such as
`_com.example/inspect`; standard methods cannot be invoked through these helpers.

Install `onExtensionRequest` and `onExtensionNotification` in either handler
record to receive custom calls. Request handlers receive a context, method name,
opaque JSON parameters, and `userData`, and return JSON or raise `AcpRpcError`.
Notification handlers receive the name, parameters, and `userData` on the ordered
callback thread. An unhandled request returns `MethodNotFound`; an unhandled
notification is ignored. Extensions never replace standard protocol handlers.

`initialize(..., extensionCapabilities = payload, meta = metadata)` and
`newAcpAgent(..., extensionCapabilities = payload, meta = metadata)` carry custom
capabilities under the corresponding capabilities' `_meta`, separately from
initialization-level `_meta`. Retained metadata is copied into shared buffers.
Applications decide which peer extension capabilities to require.

`getAvailableCommands()` returns the latest complete command catalog, including
optional input hints. An empty catalog clears previously advertised commands.
Run a command through a normal prompt, such as `session.prompt("/inspect path")`.
`getUsage()` returns `Option[UsageUpdate]` with `used`, `size`, and optional
cumulative `cost` (`amount` and `currency`). Unreported usage is `none`; a report
with zero counts is a valid snapshot. Each report replaces the previous one,
including its optional cost; values are not accumulated.

Both getters return owned snapshots updated in wire order before callbacks.
`parseAvailableCommandsUpdate` and `parseUsageUpdate` decode their `unknownUpdate`
events, and `availableCommandsUpdate` / `usageUpdate` construct notifications for
agent handlers. The existing `UpdateKind` enum and initial `session.state`
snapshot remain source compatible.

## Elicitation

Install `ClientHandlers.onElicitationForm` and/or `onElicitationUrl` to opt into
those modes. ACPort advertises only installed modes. Each handler receives an
`ElicitationRequest` and returns an `ElicitationResponse` with `acceptElicitation`,
`declineElicitation`, or `cancelElicitation`. Unknown modes/actions retain raw
payloads for forwarding and are never interpreted as acceptance. Requests for
unadvertised modes fail with `InvalidParams`.

Requests have explicit `formElicitation` or `urlElicitation` modes and either
`sessionElicitationScope` (with optional `toolCallId`) or
`requestElicitationScope`. `requestedSchema` and response `content` are JSON.
ACPort validates envelope and wire-value types; applications render the form and
validate answers against its schema. Form mode is for non-secret information.
Unknown fields and `_meta` remain available through the original raw payload.

An agent handler calls `context.requestElicitation(request, timeoutMs)` after
checking the application's desired interaction. ACPort checks the peer's mode
capability. In a constructed request-scoped envelope, an omitted `requestId`
defaults to the current context's RPC identifier. `context.getRequestId()` returns
an owned JSON identifier when explicit correlation is needed, including string
and null IDs. Request scope works during authentication before any session exists.

For URL mode, `accept` means consent to the interaction, not completion of the
external operation. The application must show the full URL and obtain consent
before opening it in a suitable external context; ACPort never opens or fetches
URLs. Use `context.completeElicitation(id, meta)` during a live handler to report
completion, and `onElicitationComplete` to observe it. Credential handling and
verification of the external user remain application responsibilities.

URL IDs are unique among outstanding flows on each connection. Completion
arriving before the consent response is buffered until acceptance; decline or
cancellation discards it. Unknown and duplicate completions are ignored. Session
cancellation/closure, parent-request cancellation, and disconnect discard the
associated URL state. Reuse an ID only after its previous flow has ended.

Elicitation callbacks run on request workers and must honor
`context.isCancelled()`. Parent cancellation produces a cancelled interaction;
explicit deadlines and transport failures retain ACPort's normal exceptions.
Completion callbacks run on the ordered callback thread. Keep all callbacks and
their `userData` alive until connection shutdown finishes.

## Permissions, cancellation, and errors

Install `ClientHandlers.onPermission` to select one of the request's option IDs.
A rejection is a `selected` outcome whose option has a rejection kind; it is
different from cancelling the permission interaction. The default handler returns
the protocol's `cancelled` outcome and never approves an action.

`session.cancel()` signals cancellation and keeps the connection open. Agent
handlers must check `context.isCancelled()` and stop their work; the original
prompt completes with the `cancelled` stop reason. A cancellation notification
does not itself receive a response. Permission handlers should also honor their
context's cancellation flag.

Blocking calls accept `timeoutMs`; zero, the default, means no deadline. Expiry
raises `AcpTimeoutError` and sends request cancellation; prompt expiry also sends
`session/cancel`. The session remains busy until the peer finishes that turn.
Use `session.isPromptActive()` to inspect whether its completion has arrived.
Timeouts do not trigger retries or kill the agent process.

`AcpRpcError` retains the remote code, message, and data. Local framing/version
errors raise `AcpProtocolError`; disconnection raises `AcpTransportError` and
wakes outstanding requests. Handler exceptions become RPC errors, rather than
leaving the caller waiting indefinitely.

## Threading and ownership

Client calls after connection setup are thread-safe. Connect, initialize, and
close from the owning thread. Stop new callers before closing; already-started
request handles may be collected after close. After `close`, the client pointer
is freed and must not be used or closed again. Release an agent only after
`runStdioAgent` returns.

Prompt and permission handlers run on a worker pool. Session setup, lifecycle and
configuration handlers run on a separate serial management thread, so a full
prompt pool cannot starve them. Protect application state accessed from both.
Update, extension-notification, elicitation-completion, and diagnostic callbacks run on one
ordered callback thread per connection. The reader and writer never invoke
application callbacks. Callbacks must return promptly and cannot make blocking
calls on the same connection; start work on another application thread instead.
The optional agent `onCancel` hook runs on the callback thread for notifications
and on the management thread during session closure. It must return promptly and
be safe on either thread. Cancellation flags are set before the hook runs.

Handlers are `nimcall, gcsafe` procedures, with an explicit application-owned
`userData` pointer. They do not capture closures. Keep that state alive until
close finishes. Locks protect shared access but **do not make thread-local Nim
strings, sequences, or JSON references transferable across threads**. Use
explicitly owned shared buffers, channels, or POD state. Callback arguments belong
to the callback thread; copy them through a suitable transfer mechanism if another
thread needs them.

`RequestContext` is valid only during its handler. Agent handlers must cooperate
with cancellation so close can join their threads. Owned subprocesses receive
stdin EOF at close, followed by bounded SIGTERM/SIGKILL escalation of their process
group if they fail to exit. All protocol stdout is JSON-RPC; child diagnostics
are drained separately and discarded unless `onLog` is installed.

Parsed tagged payloads retain their original `raw` JSON for lossless forwarding.
That raw value takes precedence when serializing. To construct a changed payload,
create a fresh typed value or clear its `raw` field first.

## Tests and live agent integration

`make test` runs deterministic Nim tests, including independent raw-wire peers.
Scripted peers are unit tests, not evidence of live integration.

Live tests exercise three real agents through the same Nim suite:

| Agent | ACP entry point | Validated version |
| --- | --- | --- |
| Codex | [codex-acp](https://github.com/agentclientprotocol/codex-acp), translating Codex App Server | Adapter 2.6.0; Codex CLI 0.167.2 |
| Grok | Native [`grok agent stdio`](https://docs.x.ai/build/cli/headless-scripting#acp) | Grok Build 1.0.77 |
| Claude | [claude-agent-acp](https://github.com/agentclientprotocol/claude-agent-acp), using the Claude Agent SDK | Adapter 0.106.0; bundled Claude CLI 2.1.322 |

Codex and Claude adapter versions are pinned. Grok uses the installed CLI, with
auto-update and shared leader mode disabled for the test subprocess. CLI output
modes such as `codex exec --json` or `claude --print` are not used as ACP transports.

```sh
make integration-setup
make integration-test
# Or run one provider:
make integration-test-codex
make integration-test-grok
make integration-test-claude
```

`integration-setup` uses npm to install both published adapters beneath ignored
`build/integration-tools`, with installation scripts disabled. Node/npm are needed
only for these external adapters, not for ACPort or its Nim test implementation.
Claude's SDK supplies its matching native CLI as a platform dependency. The
adapter dependency resolution is recorded by npm's local lock file there. Grok
must already be installed; setup does not install or upgrade the Grok CLI.

Use existing provider logins or the providers' supported API-key environment.
Grok explicitly authenticates with an advertised `cached_token` or `xai.api_key`
method and `_meta.headless = true`. Tests never start an interactive login.
Grok sessions disable automatic approval; Claude sessions use manual mode and
test-local SDK settings/MCP configuration. Global configuration is not edited.

| Override | Purpose |
| --- | --- |
| `ACPORT_CODEX_ACP` | Existing codex-acp executable, matching the pinned version |
| `ACPORT_GROK` | Installed Grok executable path |
| `ACPORT_CLAUDE_ACP` | Existing claude-agent-acp executable, matching the pinned version |
| `ACPORT_TEST_MODEL` | Optional Codex model override |
| `ACPORT_GROK_MODEL` | Optional Grok model override |
| `ACPORT_CLAUDE_MODEL` | Optional Claude model override |

Without model overrides, each provider's configured default is preserved. Codex
uses the installed `codex` through `CODEX_PATH`. Claude's adapter honors its
upstream `CLAUDE_CODE_EXECUTABLE` override if a different native CLI is required.

The suite exercises both direct connections and a real Nim relay for every agent,
using ACPort's agent and client APIs. It verifies streaming, multiple turns,
persisted context after restart, approved and rejected file writes, cancellation,
and another successful turn afterward. It also exercises readiness polling,
typed command catalogs, usage where reported, advertised model and reasoning
settings, legacy modes where available, filtered
listing, close/resume without replay, and closing an active turn while retaining
a usable connection.
Claude additionally exercises a real form elicitation through both direct and
relay paths. Deterministic independent wire peers cover extension calls, both
elicitation scopes and modes, URL completion races, and cancellation. URL tests
use non-resolving fixture URLs and never perform a real browser/OAuth flow.
Work occurs in temporary directories.
Missing tools, credentials, or required interactions fail rather than skip.
Separate per-agent direct/relay event and stderr transcripts stay under ignored `build/`.

This is tested core v1 interoperability, not full-protocol conformance certification.

## License

MIT.
