import
  std/[atomics, json, locks, monotimes, os, osproc, streams, strtabs, strutils, tempfiles, times, unittest],
  acport,
  acport/connection

type
  Capture = object
    lock: Lock
    text: SharedText
    updates, decisions, permissionMode: int
  BlockingCall = object
    client: AcpClient
    directory: SharedText
    transportFailed: Atomic[bool]

proc blockedSessionCreation(state: ptr BlockingCall) {.thread.} =
  ## Exercise a public API operation while the owner closes its connection.
  try:
    discard state.client.newSession(localText(state.directory), timeoutMs = 5000)
  except AcpTransportError:
    state.transportFailed.store(true)

proc captureUpdate(update: SessionUpdate, userData: pointer) {.gcsafe.} =
  ## Collect updates under a lock so assertions can inspect them safely.
  let capture = cast[ptr Capture](userData)
  withLock capture.lock:
    inc capture.updates
    if update.kind in {agentMessageChunk, userMessageChunk}:
      let text = localText(capture.text) & update.content.text
      freeText(capture.text)
      capture.text = sharedText(text)

proc capturedText(capture: ptr Capture): string =
  ## Copy callback-owned text into the asserting thread.
  withLock capture.lock: result = localText(capture.text)

proc decide(context: RequestContext, request: PermissionRequest,
    userData: pointer): PermissionOutcome {.gcsafe.} =
  ## Select known options or wait for protocol cancellation.
  let capture = cast[ptr Capture](userData)
  var mode: int
  withLock capture.lock:
    inc capture.decisions
    mode = capture.permissionMode
  if mode == 2:
    while not context.isCancelled(): sleep(5)
    return PermissionOutcome(outcome: "cancelled")
  PermissionOutcome(outcome: "selected", optionId: if mode == 1: "no" else: "yes")

proc newCapture(): ptr Capture =
  ## Allocate shared test callback state.
  result = cast[ptr Capture](allocShared0(sizeof(Capture)))
  initLock(result.lock)

proc freeCapture(capture: ptr Capture) =
  ## Release callback state after all connection threads have joined.
  freeText(capture.text)
  deinitLock(capture.lock)
  deallocShared(capture)

proc connectFixture(capture: ptr Capture): AcpClient =
  ## Start a fixture with callbacks and a bounded handshake.
  result = newAcpClient("tests", "1", ClientHandlers(onUpdate: captureUpdate,
    onPermission: decide, userData: capture))
  result.connect(absolutePath("build/fixture-agent"))
  discard result.initialize(5000)

proc rawSend(process: Process, value: JsonNode) =
  ## Write a hand-built wire message without ACPort's encoder.
  process.inputStream.writeLine($value)
  process.inputStream.flush()

proc rawRead(process: Process): JsonNode =
  ## Read a fixture response with the standard library alone.
  parseJson(process.outputStream.readLine())

suite "threaded stdio":
  test "close wakes a blocked session-creation call on another thread":
    let
      directory = createTempDir("acport-close-", "")
      slowDirectory = directory / "slow-creation"
      capture = newCapture()
      client = connectFixture(capture)
      state = cast[ptr BlockingCall](allocShared0(sizeof(BlockingCall)))
    defer: removeDir(directory)
    defer: freeCapture(capture)
    defer:
      freeText(state.directory)
      deallocShared(state)
    createDir(slowDirectory)
    state.client = client
    state.directory = sharedText(slowDirectory)
    var thread: Thread[ptr BlockingCall]
    createThread(thread, blockedSessionCreation, state)
    for attempt in 0 ..< 1000:
      if capture.capturedText() == "creating": break
      sleep(5)
    check capture.capturedText() == "creating"
    client.close()
    joinThread(thread)
    check state.transportFailed.load()

  test "advertised authentication is explicit and gated by the application":
    let
      directory = createTempDir("acport-auth-", "")
      client = newAcpClient("tests", "1")
    defer: removeDir(directory)
    defer: client.close()
    client.connect(absolutePath("build/fixture-agent"), @["auth"])
    let info = client.initialize(5000)
    check info.authMethods.len == 1
    expect AcpRpcError: discard client.newSession(directory, timeoutMs = 5000)
    expect AcpProtocolError: client.authenticate("not-advertised", 5000)
    client.authenticate("fixture-key", 5000)
    let session = client.newSession(directory, timeoutMs = 5000)
    check session.prompt("authenticated", 5000).stopReason == endTurn

  test "child cwd and environment do not change the parent":
    let
      directory = createTempDir("acport-launch-", "")
      parentDirectory = getCurrentDir()
      capture = newCapture()
      client = newAcpClient("tests", "1", ClientHandlers(onUpdate: captureUpdate, userData: capture))
    defer: removeDir(directory)
    defer: freeCapture(capture)
    defer: client.close()
    client.connect(absolutePath("build/raw-agent"), workingDir = directory,
      environment = newStringTable("ACPORT_LAUNCH_TEST", "child-value", modeCaseSensitive))
    discard client.initialize(5000)
    let session = client.newSession(directory, timeoutMs = 5000)
    discard session.prompt("cwd-env", 5000)
    check capture.capturedText() == directory & ":child-value"
    check getCurrentDir() == parentDirectory
    check getEnv("ACPORT_LAUNCH_TEST") == ""

  test "other children do not inherit pipe handles and delay close":
    let
      first = newAcpClient("first", "1")
      second = newAcpClient("second", "1")
    defer: second.close()
    first.connect(absolutePath("build/raw-agent"))
    discard first.initialize(5000)
    second.connect(absolutePath("build/raw-agent"))
    discard second.initialize(5000)
    let started = getMonoTime()
    first.close()
    check (getMonoTime() - started).inMilliseconds < 2000
    discard second.newSession(getTempDir(), timeoutMs = 5000)

  test "raw agent validates outgoing wire and fragmented Unicode input":
    let
      capture = newCapture()
      client = newAcpClient("tests", "1", ClientHandlers(onUpdate: captureUpdate, userData: capture))
    defer: freeCapture(capture)
    defer: client.close()
    client.connect(absolutePath("build/raw-agent"))
    discard client.initialize(5000)
    let session = client.newSession(getTempDir(), timeoutMs = 5000)
    expect AcpProtocolError: discard client.newSession(getTempDir(), timeoutMs = 5000)
    expect AcpProtocolError: discard client.loadSession("s", getTempDir(), timeoutMs = 5000)
    check session.prompt("fragmented", 5000).stopReason == endTurn
    check capture.capturedText() == "line one\n雪🙂"
    check session.prompt("permission", 5000).stopReason == endTurn

  test "version mismatch and broken peers fail explicitly":
    block:
      let client = newAcpClient("tests", "1")
      defer: client.close()
      client.connect(absolutePath("build/raw-agent"), @["version-mismatch"])
      expect AcpProtocolError: discard client.initialize(5000)
    for mode in ["die", "incomplete", "invalid-response"]:
      let client = newAcpClient("tests", "1")
      defer: client.close()
      client.connect(absolutePath("build/raw-agent"))
      discard client.initialize(5000)
      let session = client.newSession(getTempDir(), timeoutMs = 5000)
      if mode == "die":
        expect AcpTransportError: discard session.prompt(mode, 5000)
      else:
        expect AcpProtocolError: discard session.prompt(mode, 5000)

  test "persistent sessions, ordered updates, permissions, and replay":
    let
      directory = createTempDir("acport-unit-", "")
      capture = newCapture()
    defer: removeDir(directory)
    defer: freeCapture(capture)
    var sessionId: string
    block:
      let client = connectFixture(capture)
      defer: client.close()
      let session = client.newSession(directory, timeoutMs = 5000)
      sessionId = session.id
      check session.prompt("hello", 5000).stopReason == endTurn
      check capture.capturedText() == "hello"
      check capture.updates == 2
      check session.prompt("again", 5000).stopReason == endTurn
      check capture.capturedText() == "helloagain"
      check session.prompt("permission", 5000).stopReason == endTurn
      check capture.capturedText().endsWith("selected:yes")
      withLock capture.lock: capture.permissionMode = 1
      discard session.prompt("permission", 5000)
      check capture.capturedText().endsWith("selected:no")
      expect AcpRpcError: discard session.prompt("error", 5000)
      check session.prompt("recovered", 5000).stopReason == endTurn
    block:
      let client = connectFixture(capture)
      defer: client.close()
      let loaded = client.loadSession(sessionId, directory, timeoutMs = 5000)
      check capture.capturedText().endsWith("previous user messagecreated")
      check loaded.prompt("continued", 5000).stopReason == endTurn

  test "concurrent sessions and cancellation preserve the connection":
    let
      directory = createTempDir("acport-unit-", "")
      capture = newCapture()
      client = connectFixture(capture)
    defer: removeDir(directory)
    defer: freeCapture(capture)
    defer: client.close()
    let
      first = client.newSession(directory, timeoutMs = 5000)
      second = client.newSession(directory, timeoutMs = 5000)
    var slow = first.startPrompt(@[textBlock("slow")])
    check second.prompt("parallel", 5000).stopReason == endTurn
    expect AcpRpcError: discard first.startPrompt(@[textBlock("overlap")])
    first.cancel()
    check slow.waitForPrompt(5000).stopReason == cancelled
    check first.prompt("after cancel", 5000).stopReason == endTurn

  test "cancellation interrupts an in-flight permission decision":
    let
      directory = createTempDir("acport-unit-", "")
      capture = newCapture()
      client = connectFixture(capture)
    defer: removeDir(directory)
    defer: freeCapture(capture)
    defer: client.close()
    capture.permissionMode = 2
    let session = client.newSession(directory, timeoutMs = 5000)
    var handle = session.startPrompt(@[textBlock("permission")])
    for attempt in 0 ..< 1000:
      var ready: bool
      withLock capture.lock: ready = capture.decisions > 0
      if ready: break
      sleep(5)
    check capture.decisions == 1
    session.cancel()
    check handle.waitForPrompt(5000).stopReason == cancelled
    withLock capture.lock: capture.permissionMode = 0
    check session.prompt("next turn", 5000).stopReason == endTurn

  test "deadline cancels work and close wakes an outstanding handle":
    let
      directory = createTempDir("acport-unit-", "")
      capture = newCapture()
      client = connectFixture(capture)
    defer: removeDir(directory)
    defer: freeCapture(capture)
    let session = client.newSession(directory, timeoutMs = 5000)
    expect AcpTimeoutError: discard session.prompt("slow", 200)
    for attempt in 0 ..< 1000:
      if not session.isPromptActive(): break
      sleep(5)
    check not session.isPromptActive()
    check session.prompt("after deadline", 5000).stopReason == endTurn
    var handle = session.startPrompt(@[textBlock("slow")])
    client.close()
    expect AcpTransportError: discard handle.waitForPrompt(5000)

  test "raw peer checks identifiers, notification hygiene, and error behavior":
    let process = startProcess(absolutePath("build/fixture-agent"), options = {})
    defer:
      process.terminate()
      discard process.waitForExit()
      process.close()
    process.rawSend(%*{"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": 99}})
    let initialized = process.rawRead()
    check initialized["id"] == %0
    check initialized["result"]["protocolVersion"].getInt() == 1
    process.rawSend(%*{"jsonrpc": "2.0", "method": "unknown_notification"})
    process.rawSend(%*{"jsonrpc": "2.0", "id": "string-id", "method": "missing", "params": {}})
    let missing = process.rawRead()
    check missing["id"] == %"string-id"
    check missing["error"]["code"].getInt() == MethodNotFound
    process.inputStream.writeLine("{broken")
    process.inputStream.flush()
    check process.rawRead()["error"]["code"].getInt() == ParseError
    process.rawSend(%*{"jsonrpc": "2.0", "id": nil, "method": "session/prompt", "params": {}})
    let malformed = process.rawRead()
    check malformed["id"].kind == JNull
    check malformed["error"]["code"].getInt() == InvalidParams
