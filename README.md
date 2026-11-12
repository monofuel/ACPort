# ACPort

A threaded Nim library for [Agent Client Protocol](https://agentclientprotocol.com/)
clients and agents. A sibling to [MCPort](https://github.com/monofuel/MCPort).

## ACPort 1.0

Supports core **ACP v1 over Linux stdio**, with both client and agent/server APIs:

- Version and capability negotiation, plus agent-managed authentication.
- New sessions, multiple turns, concurrent sessions, and `session/load` with history replay.
- Streamed messages, reasoning, tool reports, rich content, text diffs, and plans.
- Permission requests with explicit approval, rejection, or cancellation.
- Cooperative session cancellation and request deadlines.
- Unknown update payloads and `_meta` preservation for forwarding.

The implementation targets the stable v1 schema at
[`c392d7e9d1de01337b749c0070929933e9f6f09f`](https://github.com/agentclientprotocol/agent-client-protocol/blob/c392d7e9d1de01337b749c0070929933e9f6f09f/schema/v1/schema.json).
The package version `1.0.0` and the wire protocol version `1` are separate.

The library uses threads, locks, and condition variables, without asyncdispatch.
Its only package dependency is [jsony](https://github.com/treeform/jsony), pinned
in `nimby.lock`. HTTP libraries and MCPort are not required.

HTTP/WebSocket transport, ACP v2, client filesystem and terminal execution,
session-list/resume/close/delete methods, mode/config setters, and vendor-specific
extensions are outside 1.0. Unknown update variants remain available as raw JSON.
Client filesystem, terminal, and other unsupported capabilities are not advertised.
An agent advertises `loadSession` only when it has a load handler.

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
No browser, login, retry, or reconnect is initiated automatically.

## Agent/server

Provide an `AgentHandlers` record to `newAcpAgent`, then call `runStdioAgent`.
The required handlers are `onNewSession` and `onPrompt`; authentication, loading,
and cancellation hooks are optional. See [examples/agent.nim](examples/agent.nim)
for a complete in-memory echo agent.

Session handlers return `SessionResponse` with an application-supplied unique ID.
Load handlers restore application state and send replay updates before returning.
Prompt handlers receive typed content and return `PromptResponse` with a stop
reason. A request context provides:

- `sendUpdate`: publish structured messages, tools, diffs, or plans.
- `requestPermission`: wait for the client's decision without blocking the reader.
- `isCancelled`: check cooperative cancellation, including connection shutdown.

Agents supply their own tools, MCP connections, LLM integration, authentication
policy, and persistence. ACPort does not automatically execute reported tool calls.

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

Request handlers run on a worker pool. Update and diagnostic callbacks run on one
ordered callback thread per connection. The reader and writer never invoke
application callbacks. Callbacks must return promptly and cannot make blocking
calls on the same connection; start work on another application thread instead.
The optional agent `onCancel` hook follows the same callback-thread contract;
cancellation flags are signaled by the reader before that hook runs.

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

## Tests and Codex integration

`make test` runs deterministic Nim tests, including independent raw-wire peers.
Scripted peers are unit tests, not evidence of live integration.

Live tests use the pinned external `codex-acp` **2.6.0** adapter and an authenticated
Codex CLI. The adapter speaks ACP and translates to Codex's separate App Server
protocol; `codex exec --json` is not used as ACP.
The 1.0 release was validated with `codex-cli 0.167.2`.

```sh
make integration-setup
make integration-test
```

`integration-setup` uses npm to install the published adapter beneath ignored
`build/integration-tools`, with installation scripts disabled. Node/npm are needed
only for this external adapter, not for ACPort or its Nim test implementation.
The adapter dependency resolution is recorded by npm's local lock file there.

Use an existing Codex login or API-key environment. Browser login is disabled in
tests. `ACPORT_CODEX_ACP` can select an already installed adapter; its version must
match. `ACPORT_TEST_MODEL` optionally chooses a model; otherwise the configured
Codex default is preserved. Tests use the installed `codex` through `CODEX_PATH`.
Test-local approval/sandbox settings do not edit global Codex configuration.

The suite exercises both direct ACPort-to-Codex connections and a real Nim relay
using ACPort's agent and client APIs. It verifies streaming, multiple turns,
persisted context after restart, approved and rejected file writes, cancellation,
and another successful turn afterward. Work occurs in temporary directories.
Missing tools, credentials, or required interactions fail rather than skip.
Diagnostic event and stderr transcripts stay under ignored `build/`.

This is tested core v1 interoperability, not full-protocol conformance certification.

## License

MIT.
