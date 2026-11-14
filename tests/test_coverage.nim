import
  std/[json, locks, options, os, osproc, posix, streams, strtabs, tempfiles, unittest],
  acport,
  acport/connection,
  ./host_backend

type Capture = ptr object
  lock: Lock
  client: AcpClient
  invocation, failInitialization: SharedText
  notices, compactions, authCalls: int
  authCode: uint32
  authSignal, authCancel, breakReconnect: bool

proc openPty(master, slave: ptr cint, name: cstring, term, size: pointer): cint
  {.importc: "openpty", header: "<pty.h>".}

proc spawnChdir(actions: var Tposix_spawn_file_actions, directory: cstring): cint
  {.importc: "posix_spawn_file_actions_addchdir_np", header: "<spawn.h>".}

proc terminalAuth(invocation: TerminalAuthInvocation, data: pointer): TerminalExitStatus {.gcsafe.} =
  ## Execute only the fixture agent attached to a real Linux PTY, without opening desktop UI.
  let state = cast[Capture](data)
  withLock state.lock:
    inc state.authCalls
    let node = %*{"command": invocation.command, "args": invocation.args, "cwd": invocation.workingDir,
      "base": invocation.environment["ACPORT_AUTH_BASE"], "override": invocation.environment["ACPORT_AUTH_OVERRIDE"],
      "meta": invocation.methodInfo.meta}
    freeText(state.invocation)
    state.invocation = sharedText($node)
    if state.authCancel: raise newException(AcpCancelledError, "Fixture auth cancelled")
    if state.authSignal: return TerminalExitStatus(signal: some("SIGTERM"))
    if state.authCode != 0: return TerminalExitStatus(exitCode: some(state.authCode))
    if state.breakReconnect:
      removeFile(invocation.command)
      return TerminalExitStatus(exitCode: some(0'u32))
  var master, slave: cint
  if openPty(addr master, addr slave, nil, nil, nil) != 0: raiseOSError(osLastError())
  defer:
    discard posix.close(master)
    discard posix.close(slave)
  for fd in [master, slave]: discard fcntl(fd, F_SETFD, FD_CLOEXEC)
  var actions: Tposix_spawn_file_actions
  var attributes: Tposix_spawnattr
  let initCode = posix_spawn_file_actions_init(actions)
  if initCode != 0: raiseOSError(OSErrorCode(initCode))
  defer: discard posix_spawn_file_actions_destroy(actions)
  let attrCode = posix_spawnattr_init(attributes)
  if attrCode != 0: raiseOSError(OSErrorCode(attrCode))
  defer: discard posix_spawnattr_destroy(attributes)
  let chdirCode = spawnChdir(actions, invocation.workingDir.cstring)
  if chdirCode != 0: raiseOSError(OSErrorCode(chdirCode))
  for fd in 0.cint .. 2.cint:
    let code = posix_spawn_file_actions_adddup2(actions, slave, fd)
    if code != 0: raiseOSError(OSErrorCode(code))
  var environment: seq[string]
  for key, value in invocation.environment: environment.add(key & "=" & value)
  let argv = allocCStringArray(@[invocation.command] & invocation.args)
  let envp = allocCStringArray(environment)
  defer:
    deallocCStringArray(argv)
    deallocCStringArray(envp)
  var pid: Pid
  let code = posix_spawnp(pid, invocation.command.cstring, actions, attributes, argv, envp)
  if code != 0: raiseOSError(OSErrorCode(code))
  var status: cint
  while waitpid(pid, status, 0) < 0:
    if errno != EINTR: raiseOSError(osLastError())
  if WIFEXITED(status): result.exitCode = some(uint32(WEXITSTATUS(status)))
  else: result.signal = some($WTERMSIG(status))
  if result.exitCode.get(1) != 0:
    discard fcntl(master, F_SETFL, fcntl(master, F_GETFL) or O_NONBLOCK)
    var diagnostic = ""
    while true:
      var buffer: array[4096, char]
      let count = posix.read(master, addr buffer[0], buffer.len)
      if count <= 0: break
      let offset = diagnostic.len
      diagnostic.setLen(offset + count)
      copyMem(addr diagnostic[offset], addr buffer[0], count)
    raise newException(AcpError, "Fixture terminal login failed: " & diagnostic)
  if result.exitCode.get(1) == 0 and state.failInitialization != nil:
    writeFile(localText(state.failInitialization), "fail next initialize")

proc collect(update: SessionUpdate, data: pointer) {.gcsafe.} =
  ## Verify current compaction snapshots can be read from the ordered callback thread.
  let state = cast[Capture](data)
  let notice = update.parseNoticeUpdate()
  if notice.isSome:
    withLock state.lock: inc state.notices
  if update.parseCompactionUpdate().isSome or update.parseCompactionSummaryChunk().isSome:
    let entities = AcpSession(client: state.client, id: update.sessionId).getCompactions()
    withLock state.lock: state.compactions = entities.len

proc newCapture(): Capture =
  ## Allocate POD callback state for a test client.
  result = cast[Capture](allocShared0(sizeof(result[])))
  initLock(result.lock)

proc close(state: Capture) =
  ## Free callback state only after its client threads have joined.
  freeText(state.invocation)
  freeText(state.failInitialization)
  deinitLock(state.lock)
  deallocShared(state)

proc connect(state: Capture, minimal = false, command = ""): AcpClient =
  ## Start the full or minimal fixture with explicit event and terminal-auth support.
  result = newAcpClient("coverage", "1", ClientHandlers(onUpdate: collect,
    onTerminalAuth: terminalAuth, userData: state), ClientOptions(notices: true, compaction: true))
  state.client = result
  var environment = newStringTable(modeCaseSensitive)
  environment["ACPORT_AUTH_BASE"] = "retained"
  environment["ACPORT_AUTH_OVERRIDE"] = "base"
  environment["ACPORT_AUTH_CWD"] = getTempDir()
  if state.failInitialization != nil: environment["ACPORT_INIT_FAIL_FILE"] = localText(state.failInitialization)
  result.connect(if command.len > 0: command else: absolutePath("build/coverage-agent"),
    args = if minimal: @["minimal"] else: @[], workingDir = getTempDir(), environment = environment,
    workerThreads = 1)
  discard result.initialize(5000, extensionCapabilities = %*{"saved": true}, meta = %*{"initialize": true})

proc hostCall(client: AcpClient, methodName: string, params: JsonNode): JsonNode =
  ## Exercise public agent-side host helpers over the complete round trip.
  client.requestExtension("_host", %*{"method": methodName, "params": params,
    "sessionId": params.field("sessionId")}, 5000)

proc rpc(process: Process, methodName: string, params: JsonNode): JsonNode =
  ## Make a literal request against the ACPort agent without client-side validation.
  process.inputStream.writeLine($(%*{"jsonrpc": "2.0", "id": "wire", "method": methodName, "params": params}))
  process.inputStream.flush()
  let response = parseJson(process.outputStream.readLine())
  doAssert response["id"].getStr() == "wire"
  response

suite "v1 coverage codecs":
  test "filesystem ranges, unsigned terminal limits and metadata round trip":
    let read = %*{"sessionId": "s", "path": "/file", "line": 2, "limit": 0, "_meta": {"x": 1}, "future": true}
    check parseReadTextFileRequest(read).toJsonNode() == read
    check parseReadTextFileRequest(read).limit.get() == 0
    expect AcpRpcError: discard parseReadTextFileRequest(%*{"sessionId": "s", "path": "relative"})
    expect AcpRpcError: discard parseReadTextFileRequest(%*{"sessionId": "s", "path": "/file", "line": 0})
    expect AcpRpcError: discard parseReadTextFileRequest(%*{"sessionId": "s", "path": "/file", "limit": 4294967296'u64})
    let terminal = %*{"sessionId": "s", "command": "echo", "outputByteLimit": high(uint64),
      "args": ["literal; $value"], "env": [{"name": "X", "value": "v", "_meta": {"e": true}}]}
    check parseCreateTerminalRequest(terminal).outputByteLimit.get() == high(uint64)
    check parseCreateTerminalRequest(terminal).toJsonNode() == terminal
    for value in [%(-1), %1.5, %"12"]:
      let malformed = terminal.copy()
      malformed["outputByteLimit"] = value
      expect AcpRpcError: discard parseCreateTerminalRequest(malformed)
    expect AcpRpcError: discard parseTerminalOutputResponse(%*{"output": "x", "truncated": "no"})
    let status = %*{"exitCode": nil, "signal": "SIGTERM", "_meta": {"s": true}, "future": 1}
    check parseTerminalExitStatus(status).toJsonNode() == status
    check parseTerminalExitStatus(status).exitCode.isNone
    check parseUsage(%*{"used": high(uint64), "size": high(uint64)}).used == high(uint64)

  test "constructed nested metadata uses _meta and unknown payloads survive":
    let meta = %*{"nested": true}
    let plan = SessionUpdate(sessionId: "s", kind: planUpdate,
      entries: @[PlanEntry(content: "task", priority: "high", status: "pending", meta: meta)])
    let wire = plan.toJsonNode()
    check wire["update"]["entries"][0]["_meta"] == meta
    check not wire["update"]["entries"][0].hasKey("meta")
    check parseUpdate(wire).entries[0].meta == meta
    let tool = ToolCall(toolCallId: "t", locations: some(@[ToolLocation(path: "/file", meta: meta)]))
    check parseToolCall(tool.toJsonNode()).locations.get()[0].meta == meta
    let auth = %*{"id": "t", "name": "Terminal", "type": "terminal", "args": nil, "env": nil, "future": 1}
    check parseAuthMethod(auth).toJsonNode() == auth
    let setup = %*{"sessionId": "s", "cwd": "/tmp", "systemPrompt": nil}
    check parseSessionRequest(setup, true, true).mcpServers.len == 0
    expect AcpRpcError: discard parseSessionRequest(setup, true)

suite "negotiated session features":
  test "setup options survive new load resume and roots reset completely":
    let state = newCapture()
    defer: state.close()
    let client = state.connect()
    defer: client.close()
    let prompt = some(SystemPrompt(mode: "override", content: @[textBlock("instructions")], meta: %*{"s": true}))
    let servers = @[%*{"name": "http", "type": "http", "url": "https://example.invalid/mcp", "headers": []},
      %*{"name": "sse", "type": "sse", "url": "https://example.invalid/sse", "headers": []}]
    let first = client.newSession(getTempDir(), mcpServers = servers, timeoutMs = 5000,
      additionalDirectories = @["/one", "/two"], systemPrompt = prompt)
    check first.getSessionInfo().get().additionalDirectories == @["/one", "/two"]
    check client.listSessions(timeoutMs = 5000).sessions[0].additionalDirectories == @["/one", "/two"]
    check client.requestExtension("_setup", newJObject(), 5000)["systemPrompt"] == prompt.get().toJsonNode()
    check client.requestExtension("_setup", newJObject(), 5000)["mcpServers"] == %servers
    discard client.loadSession(first.id, getTempDir(), timeoutMs = 5000, additionalDirectories = @["/two"])
    check first.getSessionInfo().get().additionalDirectories == @["/two"]
    discard client.resumeSession(first.id, getTempDir(), timeoutMs = 5000)
    check first.getSessionInfo().get().additionalDirectories.len == 0
    check not client.requestExtension("_setup", newJObject(), 5000).hasKey("systemPrompt")
    let rich = @[ContentBlock(kind: imageContent, data: "aA==", mimeType: "image/png"),
      ContentBlock(kind: audioContent, data: "aA==", mimeType: "audio/wav"),
      ContentBlock(kind: resourceContent, resource: %*{"uri": "file:///file", "text": "context"})]
    check first.prompt(rich, 5000).stopReason == endTurn

  test "unsupported fields are rejected before handlers and minimal capabilities remain absent":
    let process = startProcess(absolutePath("build/coverage-agent"), args = @["minimal"], options = {})
    defer:
      process.inputStream.close()
      discard process.waitForExit(5000)
      process.close()
    let init = process.rpc("initialize", %*{"protocolVersion": 1, "clientCapabilities": {}})["result"]
    check init["authMethods"].len == 1
    check init["agentCapabilities"]["sessionCapabilities"] == newJObject()
    for setup in [%*{"cwd": "/tmp", "mcpServers": [], "additionalDirectories": ["/extra"]},
        %*{"cwd": "/tmp", "mcpServers": [], "systemPrompt": {"mode": "append", "content": [{"type": "text", "text": "x"}]}}]:
      check process.rpc("session/new", setup)["error"]["code"].getInt() == InvalidParams
    check process.rpc("_setup", newJObject())["result"].kind == JNull
    check process.rpc("authenticate", %*{"methodId": "terminal"})["error"]["code"].getInt() == InvalidParams

  test "unsupported modes and nontext system prompts fail without creating sessions":
    let process = startProcess(absolutePath("build/coverage-agent"), options = {})
    defer:
      process.inputStream.close()
      discard process.waitForExit(5000)
      process.close()
    let caps = process.rpc("initialize", %*{"protocolVersion": 1, "clientCapabilities": {}})["result"]["agentCapabilities"]
    check caps["mcpCapabilities"] == %*{"http": true, "sse": true}
    for system in [%*{"mode": "future", "content": [{"type": "text", "text": "x"}]},
        %*{"mode": "append", "content": []},
        %*{"mode": "append", "content": [{"type": "image", "data": "x", "mimeType": "image/png"}]}]:
      check process.rpc("session/new", %*{"cwd": "/tmp", "mcpServers": [], "systemPrompt": system})["error"]["code"].getInt() == InvalidParams
    check process.rpc("_setup", newJObject())["result"].kind == JNull
    check process.rpc("session/resume", %*{"sessionId": "saved", "cwd": "/tmp"}).hasKey("result")

  test "append is supported without implicitly advertising override":
    let process = startProcess(absolutePath("build/coverage-agent"), args = @["append-only"], options = {})
    defer:
      process.inputStream.close()
      discard process.waitForExit(5000)
      process.close()
    let init = process.rpc("initialize", %*{"protocolVersion": 1, "clientCapabilities": {}})["result"]
    check init["agentCapabilities"]["sessionCapabilities"]["systemPrompt"] == newJObject()
    check process.rpc("session/new", %*{"cwd": "/tmp", "mcpServers": [],
      "systemPrompt": {"mode": "append", "content": [{"type": "text", "text": "append me"}]}}).hasKey("result")
    check process.rpc("session/new", %*{"cwd": "/tmp", "mcpServers": [],
      "systemPrompt": {"mode": "override", "content": [{"type": "text", "text": "reject me"}]}})["error"]["code"].getInt() == InvalidParams
    check process.rpc("session/list", newJObject())["result"]["sessions"].len == 1

  test "client lifecycle helpers reject absent deletion and logout capabilities":
    let state = newCapture()
    defer: state.close()
    let client = state.connect(minimal = true)
    defer: client.close()
    expect AcpProtocolError: discard client.deleteSession("stored", 5000)
    expect AcpProtocolError: discard client.logout(5000)
    expect AcpRpcError:
      discard client.newSession(getTempDir(), timeoutMs = 5000,
        systemPrompt = some(SystemPrompt(mode: "append", content: @[textBlock("unsupported")])) )

  test "delete is idempotent and logout gates fixture sessions without closing active ones":
    let state = newCapture()
    defer: state.close()
    let client = state.connect()
    defer: client.close()
    let session = client.newSession(getTempDir(), timeoutMs = 5000)
    let meta = %*{"operation": true}
    check client.deleteSession(session.id, 5000, meta).meta == meta
    discard client.deleteSession(session.id, 5000)
    check client.listSessions(timeoutMs = 5000).sessions.len == 0
    check session.prompt("still active", 5000).stopReason == endTurn
    check client.logout(5000, meta).meta == meta
    expect AcpRpcError: discard client.newSession(getTempDir(), timeoutMs = 5000)
    check session.prompt("agent-owned policy", 5000).stopReason == endTurn
    client.authenticate("agent", 5000)
    discard client.newSession(getTempDir(), timeoutMs = 5000)

  test "notices are transient and compaction chunks patch owned ordered state":
    let state = newCapture()
    defer: state.close()
    let client = state.connect()
    defer: client.close()
    let session = client.newSession(getTempDir(), timeoutMs = 5000)
    discard session.prompt("events", 5000)
    var entities = session.getCompactions()
    check entities.len == 2
    check entities[0].compactionId == "first"
    check entities[0].summary.len == 2
    check entities[0].summary[1].text == "two"
    check entities[0].status == "completed"
    check entities[0].meta == %*{"entity": 1}
    check entities[1].summary[0].text == "replacement"
    withLock state.lock:
      check state.notices == 1
      check state.compactions == 2
    entities[0].raw["status"] = %"corrupted"
    check session.getCompactions()[0].status == "completed"
    discard session.prompt("clear", 5000)
    entities = session.getCompactions()
    check entities[0].summary.len == 0
    check entities[0].error.isNone
    check entities[0].meta.kind == JNull
    check entities[1].summary.len == 0

  test "optional events cannot be sent to a client that did not opt in":
    let client = newAcpClient("no-events", "1")
    defer: client.close()
    client.connect(absolutePath("build/coverage-agent"))
    discard client.initialize(5000)
    let session = client.newSession(getTempDir(), timeoutMs = 5000)
    expect AcpRpcError: discard session.prompt("events", 5000)
    check session.getCompactions().len == 0

suite "Linux callback-backed host operations":
  test "filesystem capabilities are independent and unadvertised helper calls fail":
    let root = createTempDir("acport-readonly-", "")
    defer: removeDir(root)
    let host = newTestHost(root)
    defer: host.close()
    let client = newAcpClient("read-only", "1",
      ClientHandlers(onReadTextFile: host.handlers().onReadTextFile, userData: host))
    defer: client.close()
    client.connect(absolutePath("build/coverage-agent"))
    discard client.initialize(5000)
    let caps = client.requestExtension("_caps", newJObject(), 5000)["clientCapabilities"]
    check caps["fs"] == %*{"readTextFile": true, "writeTextFile": false}
    check not caps.hasKey("terminal")
    let session = client.newSession(root, timeoutMs = 5000)
    let params = %*{"sessionId": session.id, "path": root / "unsaved.txt", "content": "new"}
    check client.hostCall("fs/read_text_file", params)["content"].getStr() == "α\nbuffer\nthree\n"
    expect AcpRpcError: discard client.hostCall("fs/write_text_file", params)
    expect AcpRpcError: discard client.hostCall("terminal/create", %*{"sessionId": session.id, "command": "false"})

  test "relay forwards all host methods through the negotiated outer callbacks":
    let root = createTempDir("acport-relay-", "")
    defer: removeDir(root)
    let host = newTestHost(root)
    defer: host.close()
    let client = newAcpClient("relay-host", "1", host.handlers())
    defer: client.close()
    let environment = newStringTable("ACPORT_TEST_AGENT", "codex", "ACPORT_TEST_HOST_IO", "1",
      "ACPORT_TEST_FIXTURE", absolutePath("build/coverage-agent"), modeCaseSensitive)
    client.connect(absolutePath("build/agent-relay"), environment = environment)
    discard client.initialize(5000)
    let session = client.newSession(root, timeoutMs = 5000)
    let file = %*{"sessionId": session.id, "path": root / "relay.txt", "content": "relay"}
    discard client.hostCall("fs/write_text_file", file)
    check client.hostCall("fs/read_text_file", file)["content"].getStr() == "relay"
    let terminal = client.hostCall("terminal/create", %*{"sessionId": session.id,
      "command": "/bin/sh", "args": ["-c", "printf relay; exit 0"]})["terminalId"].getStr()
    let params = %*{"sessionId": session.id, "terminalId": terminal}
    check client.hostCall("terminal/wait_for_exit", params)["exitCode"].getInt() == 0
    check client.hostCall("terminal/output", params)["output"].getStr() == "relay"
    discard client.hostCall("terminal/kill", params)
    discard client.hostCall("terminal/release", params)

  test "all seven helpers preserve host policy, file contents and terminal lifecycle":
    let root = createTempDir("acport-host-", "")
    defer: removeDir(root)
    let host = newTestHost(root)
    defer: host.close()
    let client = newAcpClient("host", "1", host.handlers())
    defer: client.close()
    client.connect(absolutePath("build/coverage-agent"))
    discard client.initialize(5000)
    let session = client.newSession(root, timeoutMs = 5000)
    let file = %*{"sessionId": session.id, "path": root / "file.txt", "content": "α\nβ\n", "_meta": {"file": true}}
    check client.hostCall("fs/write_text_file", file)["_meta"] == %*{"file": true}
    check readFile(root / "file.txt") == "α\nβ\n"
    check client.hostCall("fs/read_text_file", %*{"sessionId": session.id, "path": root / "file.txt"})["content"].getStr() == "α\nβ\n"
    expect AcpRpcError: discard client.hostCall("fs/read_text_file", %*{"sessionId": session.id, "path": "/outside"})
    let terminal = client.hostCall("terminal/create", %*{"sessionId": session.id, "command": "/bin/sh",
      "args": ["-c", "printf '%s' \"$ACPORT_UNICODE\"; exit 7"], "env": [{"name": "ACPORT_UNICODE", "value": "αβγδ"}],
      "cwd": root, "outputByteLimit": 5})["terminalId"].getStr()
    let params = %*{"sessionId": session.id, "terminalId": terminal}
    check client.hostCall("terminal/wait_for_exit", params)["exitCode"].getInt() == 7
    let output = client.hostCall("terminal/output", params)
    check output["output"].getStr() == "γδ"
    check output["truncated"].getBool()
    check client.hostCall("terminal/output", params) == output
    expect AcpRpcError: discard client.hostCall("terminal/output", %*{"sessionId": "other", "terminalId": terminal})
    discard client.hostCall("terminal/kill", params)
    discard client.hostCall("terminal/release", params)
    expect AcpRpcError: discard client.hostCall("terminal/output", params)

  test "literal reverse requests keep control available with every ordinary worker waiting":
    for mode in ["host", "cancel-wait", "release-wait"]:
      let root = createTempDir("acport-wire-", "")
      defer: removeDir(root)
      let host = newTestHost(root)
      defer: host.close()
      let client = newAcpClient("wire", "1", host.handlers())
      defer: client.close()
      client.connect(absolutePath("build/coverage-raw"), @[mode], workerThreads = 1)
      discard client.initialize(5000)
      let session = client.newSession(root, timeoutMs = 5000)
      var turn = session.startPrompt(@[textBlock("host")])
      for attempt in 0 ..< 1000:
        if host.activeWaits() == 1: break
        sleep(5)
      check host.activeWaits() == 1
      if mode != "cancel-wait": check client.requestExtension("_control", newJObject(), 5000)["controlled"].getBool()
      else: session.cancel()
      check turn.waitForPrompt(5000).stopReason == (if mode == "cancel-wait": cancelled else: endTurn)
      check readFile(root / "written.txt") == "wire text"

  test "disconnect cancels a blocked terminal wait and the host can reap remaining children":
    let root = createTempDir("acport-close-", "")
    defer: removeDir(root)
    let host = newTestHost(root)
    defer: host.close()
    let client = newAcpClient("disconnect", "1", host.handlers())
    client.connect(absolutePath("build/coverage-raw"), workerThreads = 1)
    discard client.initialize(5000)
    let session = client.newSession(root, timeoutMs = 5000)
    var turn = session.startPrompt(@[textBlock("host")])
    for attempt in 0 ..< 1000:
      if host.activeWaits() == 1: break
      sleep(5)
    check host.activeWaits() == 1
    client.close()
    check host.activeWaits() == 0
    expect AcpTransportError: discard turn.waitForPrompt(5000)

  test "unsupported host methods are not advertised or dispatched":
    let client = newAcpClient("unsupported", "1")
    defer: client.close()
    client.connect(absolutePath("build/coverage-raw"), @["unsupported"])
    discard client.initialize(5000)
    let session = client.newSession(getTempDir(), timeoutMs = 5000)
    check session.prompt("host", 5000).stopReason == endTurn
    let host = newTestHost(getTempDir())
    defer: host.close()
    var partial = host.handlers()
    partial.onKillTerminal = nil
    expect ValueError: discard newAcpClient("partial", "1", partial)

suite "terminal authentication":
  test "base invocation arguments are retained and auth arguments are appended":
    let state = newCapture()
    defer: state.close()
    let client = state.connect(minimal = true)
    defer: client.close()
    discard client.authenticateTerminal("terminal", 5000)
    check parseJson(localText(state.invocation))["args"] == %*["minimal", "--terminal-auth"]

  test "successful PTY login restores initialization and invalidates old session handles":
    let state = newCapture()
    defer: state.close()
    let client = state.connect()
    defer: client.close()
    let oldSession = client.newSession(getTempDir(), timeoutMs = 5000)
    var turn = oldSession.startPrompt(@[textBlock("hold")])
    expect AcpProtocolError: client.authenticate("terminal", 5000)
    let info = client.authenticateTerminal("terminal", 5000)
    check info.authMethods.len == 2
    check turn.isReady()
    expect AcpTransportError: discard turn.waitForPrompt(5000)
    expect AcpProtocolError: discard oldSession.startPrompt(@[textBlock("stale")])
    let invocation = parseJson(localText(state.invocation))
    check invocation["args"] == %*["--terminal-auth"]
    check invocation["base"].getStr() == "retained"
    check invocation["override"].getStr() == "terminal"
    check invocation["meta"] == %*{"auth": true}
    let caps = client.requestExtension("_caps", newJObject(), 5000)
    check caps["clientCapabilities"]["_meta"] == %*{"saved": true}
    check caps["clientCapabilities"]["session"]["compaction"].kind == JObject
    check caps["_meta"] == %*{"initialize": true}
    discard client.loadSession(oldSession.id, getTempDir(), timeoutMs = 5000)

  test "failed cancelled and signalled callbacks leave the current connection usable":
    let state = newCapture()
    defer: state.close()
    let client = state.connect()
    defer: client.close()
    let session = client.newSession(getTempDir(), timeoutMs = 5000)
    state.authCode = 3
    expect AcpError: discard client.authenticateTerminal("terminal", 5000)
    state.authCode = 0
    state.authSignal = true
    expect AcpError: discard client.authenticateTerminal("terminal", 5000)
    state.authSignal = false
    state.authCancel = true
    expect AcpCancelledError: discard client.authenticateTerminal("terminal", 5000)
    check session.prompt("connection preserved", 5000).stopReason == endTurn

  test "failed respawn leaves a disconnected client that can explicitly connect again":
    let root = createTempDir("acport-auth-", "")
    defer: removeDir(root)
    let executable = root / "fixture"
    copyFile(absolutePath("build/coverage-agent"), executable)
    setFilePermissions(executable, {fpUserRead, fpUserWrite, fpUserExec})
    let state = newCapture()
    defer: state.close()
    let client = state.connect(command = executable)
    defer: client.close()
    state.breakReconnect = true
    # Return success without launching the removed fixture so only respawn fails.
    state.authCode = 0
    expect OSError: discard client.authenticateTerminal("terminal", 5000)
    client.connect(absolutePath("build/coverage-agent"))
    discard client.initialize(5000)

  test "failed reinitialization cleans up the replacement connection":
    let root = createTempDir("acport-init-failure-", "")
    defer: removeDir(root)
    let state = newCapture()
    state.failInitialization = sharedText(root / "fail-initialize")
    defer: state.close()
    let client = state.connect()
    defer: client.close()
    expect AcpTransportError: discard client.authenticateTerminal("terminal", 5000)
    client.connect(absolutePath("build/coverage-agent"))
    discard client.initialize(5000)
