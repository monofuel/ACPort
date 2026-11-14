# ACP v1 coverage

ACPort 1.3 targets Linux stdio and the stable v1 schema at
[`c392d7e9d1de01337b749c0070929933e9f6f09f`](https://github.com/agentclientprotocol/agent-client-protocol/blob/c392d7e9d1de01337b749c0070929933e9f6f09f/schema/v1/schema.json).
All 25 named methods/notifications in that snapshot have dispatch or routing
support. This is an endpoint inventory, not a claim of formal ACP certification
or exhaustive acceptance of every malformed/forward-compatible schema variant.

## Named methods

Both sides are implemented: the public caller/helper and the peer dispatch hook,
or the connection router for cancellation. Optional services are only advertised
when installed or explicitly declared.

| Method | Public interface / handler | Deterministic verification |
| --- | --- | --- |
| `initialize` | `initialize`, agent initialization | `test_stdio`, `test_coverage` |
| `authenticate` | `authenticate`, `onAuthenticate` | `test_stdio`, `test_features`, `test_coverage` |
| `logout` | `logout`, `onLogout` | `test_coverage`: fixture authentication gate |
| `session/new` | `newSession`, `onNewSession` | `test_stdio`, `test_coverage` |
| `session/load` | `loadSession`, `onLoadSession` | `test_stdio`, `test_sessions`, `test_coverage` |
| `session/resume` | `resumeSession`, `onResumeSession` | `test_sessions`, `test_coverage` |
| `session/list` | `listSessions`, `onListSessions` | `test_sessions`, `test_coverage` |
| `session/close` | `closeSession`, `onCloseSession` | `test_sessions`: saturation and cancellation |
| `session/delete` | `deleteSession`, `onDeleteSession` | `test_coverage`: idempotency and independent active state |
| `session/prompt` | `startPrompt` / `prompt`, `onPrompt` | `test_stdio`, `test_coverage`: rich content |
| `session/cancel` | `cancel`, `onCancel`, connection tokens | `test_stdio`, `test_sessions`, `test_coverage` |
| `session/set_config_option` | `setConfigOption`, `onSetConfigOption` | `test_sessions` |
| `session/set_mode` | `setMode`, `onSetMode` | `test_sessions` |
| `session/update` | `sendUpdate`, `onUpdate`, owned snapshots | `test_protocol`, `test_features`, `test_coverage` |
| `session/request_permission` | `requestPermission`, `onPermission` | `test_stdio`, `test_sessions` |
| `fs/read_text_file` | `readTextFile`, `onReadTextFile` | `test_coverage`: ranges, buffers, raw wire, relay |
| `fs/write_text_file` | `writeTextFile`, `onWriteTextFile` | `test_coverage`: file policy, raw wire, relay |
| `terminal/create` | `createTerminal`, `onCreateTerminal` | `test_coverage`: real Linux child, env/cwd, relay |
| `terminal/output` | `terminalOutput`, `onTerminalOutput` | `test_coverage`: retained UTF-8 output and exit status |
| `terminal/wait_for_exit` | `waitForTerminalExit`, `onWaitForTerminalExit` | `test_coverage`: normal/signal exit and cancellation |
| `terminal/kill` | `killTerminal`, `onKillTerminal` | `test_coverage`: worker saturation and retained identity |
| `terminal/release` | `releaseTerminal`, `onReleaseTerminal` | `test_coverage`: invalidated IDs and host cleanup |
| `elicitation/create` | `requestElicitation`, form/URL handlers | `test_features` |
| `elicitation/complete` | `completeElicitation`, `onElicitationComplete` | `test_features`: correlation, early and duplicate completion |
| `$/cancel_request` | request deadlines and connection tokens | `test_features`, `test_coverage`: blocked host wait |

## Negotiated features and fields

| Surface | Coverage |
| --- | --- |
| Session setup | Typed ordered `additionalDirectories`, append/override `systemPrompt`, optional resume MCP list; unsupported system instructions fail before dispatch. |
| Session descriptors | Typed current additional roots, title/timestamp patches, paging and opaque cursors. |
| Agent capabilities | Explicit rich prompt, MCP HTTP/SSE, additional-root and system-prompt declarations; lifecycle/logout capabilities follow handlers. MCP execution remains application-owned. |
| Client capabilities | Independent file operations; all-or-none terminal bundle; explicit notice/compaction opt-in; terminal auth and elicitation follow installed callbacks. |
| Authentication | Agent/headless `_meta`, terminal descriptors, host PTY fixture, successful reconnect, failure preservation, restored initialization, stale session rejection. Logout never runs against live provider accounts in tests. |
| Session updates | All 14 pinned discriminators decode through typed fields or typed helpers. `UpdateKind` remains source compatible. |
| Compaction | First-seen ordering, summary chunks, replacement patches, null clears, transient chunk metadata, owned snapshots before callbacks. |
| Extensibility | Bidirectional `_` methods, unknown updates/tagged payloads, original raw representations, `_meta` on plan entries, tool locations/content, diffs, and permission outcomes. |
| Unsigned values | Terminal limits and usage counts include the full uint64 range; read ranges and exit codes retain uint32 bounds. |

Some optional presentation fields remain available through raw JSON rather than
dedicated typed properties, including resource-link title/description/size and
image URI. Embedded resources, MCP configurations, form schemas, capabilities,
and arbitrary `_meta` contents intentionally retain JSON representations. ACPort
validates protocol envelopes; application permissions, form validation, terminal
storage, authentication policy, session persistence, and model behavior are not
library implementations. Schema `x-deserialize-*` recovery hints are not an
exhaustive compatibility guarantee: malformed known payloads can raise errors.

## Verification boundaries

`make test-arc` and `make test-orc` run all deterministic suites, including raw
peers independent of ACPort codecs, real Linux child processes, an interactive
PTY authentication fixture, and a two-hop host-I/O relay. Fixture credentials and
history isolate logout/deletion tests from real accounts.

`make integration-test` exercises real Codex, Grok, and Claude, directly and
through the agent/client relay. It verifies streaming, sessions, configuration,
permissions, cancellation, and reuse; Claude also exercises form elicitation.
Those six cases do not establish that providers use every optional v1 method.
The pinned Codex/Claude adapters largely execute I/O themselves. Host-I/O dispatch
and forwarding are verified with deterministic fixtures rather than inferred
from successful model responses.

The test relay's explicit `ACPORT_TEST_HOST_IO=1` profile installs backend host
callbacks and requires the matching outer filesystem/terminal capabilities before
creating a session. `ACPORT_TEST_FIXTURE` selects the deterministic backend without
provider authentication. This is test infrastructure, not a general proxy product.

macOS/Windows, remote HTTP/WebSocket transports, ACP v2, draft/vendor extensions,
and production filesystem/process/PTY backends are outside the Linux 1.x surface.
