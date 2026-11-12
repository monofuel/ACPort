import
  std/[json, locks, options, os, osproc, streams, strutils, unittest],
  acport,
  acport/connection

type Capture = object
  lock: Lock
  text: SharedText
  observed: SharedText
  client: AcpClient
  decisions: int

proc update(update: SessionUpdate, data: pointer) {.gcsafe.} =
  ## Collect only owned text across the callback thread boundary.
  let capture = cast[ptr Capture](data)
  if update.parseConfigOptionUpdate().isSome and capture.client != nil:
    let value = AcpSession(client: capture.client, id: update.sessionId).getConfigOptions()[0].currentValue.stringValue
    withLock capture.lock:
      freeText(capture.observed)
      capture.observed = sharedText(value)
  if update.kind == agentMessageChunk:
    withLock capture.lock:
      let text = localText(capture.text) & update.content.text
      freeText(capture.text)
      capture.text = sharedText(text)

proc permission(context: RequestContext, request: PermissionRequest,
    data: pointer): PermissionOutcome {.gcsafe.} =
  ## Hold a permission decision until close cancels its parent prompt.
  let capture = cast[ptr Capture](data)
  withLock capture.lock: inc capture.decisions
  while not context.isCancelled(): sleep(5)
  PermissionOutcome(outcome: "cancelled")

proc captured(capture: ptr Capture): string =
  ## Copy the synchronized callback text.
  withLock capture.lock: result = localText(capture.text)

proc newCapture(): ptr Capture =
  ## Allocate POD callback state.
  result = cast[ptr Capture](allocShared0(sizeof(Capture)))
  initLock(result.lock)

proc freeCapture(capture: ptr Capture) =
  ## Release state after connection shutdown joins callbacks.
  freeText(capture.text)
  freeText(capture.observed)
  deinitLock(capture.lock)
  deallocShared(capture)

proc connect(capture: ptr Capture = nil, style = ""): AcpClient =
  ## Launch a session fixture with a one-thread prompt pool.
  result = newAcpClient("sessions", "1", ClientHandlers(onUpdate: update,
    onPermission: permission, userData: capture))
  result.connect(absolutePath("build/session-agent"), if style == "": @[] else: @[style])
  discard result.initialize(5000)

suite "session configuration codecs":
  test "grouped choices, booleans, unknown options and metadata round trip":
    let wire = parseJson("""[
      {"id":"model","name":"Model","type":"select","currentValue":"a",
       "category":"model","_meta":{"extension":1},"options":[
       {"group":"g","name":"Group","options":[{"value":"a","name":"A"}]}]},
      {"id":"flag","name":"Flag","type":"boolean","currentValue":true},
      {"id":"future","name":"Future","type":"slider","currentValue":9}]
    """)
    let options = parseConfigOptions(wire)
    check options.toJsonNode() == wire
    check options[0].groups[0].options[0].value == "a"
    check options[1].currentValue.boolValue
    check options[2].kind == unknownConfigOption
    validateConfigValue(options, "model", configValue("a"))
    expect AcpRpcError: validateConfigValue(options, "model", configValue("other"))
    expect AcpRpcError: validateConfigValue(options, "flag", configValue("true"))
    expect AcpRpcError: validateConfigValue(options, "future", configValue("9"))

  test "setter wire defaults to id and discriminates booleans":
    let request = SetConfigOptionRequest(sessionId: "s", configId: "x", value: configValue(true))
    check request.toJsonNode()["type"].getStr() == "boolean"
    check parseSetConfigOption(request.toJsonNode()).value.boolValue
    check parseSetConfigOption(%*{"sessionId":"s", "configId":"x", "value":"a"}).value.stringValue == "a"
    expect AcpRpcError:
      discard parseSetConfigOption(%*{"sessionId":"s", "configId":"x", "type":"boolean", "value":"true"})
    expect AcpRpcError:
      discard parseSetConfigOption(%*{"sessionId":"s", "configId":"x", "type":3, "value":"a"})

  test "metadata patches retain null versus omission and the old update enum":
    let patch = sessionInfoUpdate("s", SessionInfoUpdate(titlePresent: true))
    let decoded = patch.parseSessionInfoUpdate().get()
    check decoded.titlePresent
    check decoded.title.isNone
    check not decoded.updatedAtPresent
    check patch.kind == unknownUpdate
    check parseListSessionsRequest(newJObject()).cursor.isNone
    check ListSessionsRequest().toJsonNode() == newJObject()

suite "session management":
  test "late replies apply state before callbacks and newer wire updates win":
    let capture = newCapture()
    defer: freeCapture(capture)
    let client = newAcpClient("late", "1", ClientHandlers(onUpdate: update, userData: capture))
    defer: client.close()
    capture.client = client
    client.connect(absolutePath("build/raw-agent"), @["sessions"])
    discard client.initialize(5000)
    let session = client.newSession(getTempDir(), timeoutMs = 5000)
    let page = client.listSessions(timeoutMs = 5000)
    check page.sessions[0].sessionId == "stored"
    let dormant = AcpSession(client: client, id: "stored")
    check dormant.getSessionInfo().get().title.get() == "Dormant"
    expect AcpRpcError: discard dormant.startPrompt(@[textBlock("inactive")])
    expect AcpTimeoutError: discard session.setConfigOption("x", "b", 25)
    discard session.prompt("late-config", 5000)
    check session.getConfigOptions()[0].currentValue.stringValue == "c"
    withLock capture.lock: check localText(capture.observed) == "c"
    session.closeSession(5000) # Normalize a remote SessionNotFound as a completed close.
    session.closeSession(5000)
    expect AcpRpcError: discard session.startPrompt(@[textBlock("closed")])

  test "configuration deadline preserves active prompts and applies the late response":
    let capture = newCapture()
    defer: freeCapture(capture)
    let client = connect(capture, "delayed-config")
    defer: client.close()
    let session = client.newSession(getTempDir(), timeoutMs = 5000)
    var turn = session.startPrompt(@[textBlock("slow")])
    for attempt in 0 ..< 1000:
      if capture.captured() == "started": break
      sleep(5)
    check capture.captured() == "started"
    expect AcpTimeoutError: discard session.setConfigOption("enabled", true, 25)
    discard client.listSessions(timeoutMs = 5000)
    check session.getConfigOptions()[2].currentValue.boolValue
    check session.isPromptActive()
    session.cancel()
    check turn.waitForPrompt(5000).stopReason == cancelled

  test "full catalogs replace state and snapshots are independent":
    let capture = newCapture()
    defer: freeCapture(capture)
    let client = connect(capture)
    defer: client.close()
    let session = client.newSession(getTempDir(), timeoutMs = 5000)
    let initial = session.state.configOptions
    check session.getConfigOptions().len == 3
    let updated = session.setConfigOption("model", "large", 5000)
    check updated[1].currentValue.stringValue == "high"
    check session.getConfigOptions()[0].currentValue.stringValue == "large"
    check session.state.configOptions == initial
    var copy = session.getConfigOptions()
    copy[0].raw["currentValue"] = %"corrupt"
    check session.getConfigOptions()[0].currentValue.stringValue == "large"
    discard session.setConfigOption("enabled", true, 5000)
    check session.getConfigOptions()[2].currentValue.boolValue
    expect AcpRpcError: discard session.setConfigOption("model", true, 5000)
    expect AcpRpcError: discard session.setConfigOption("reasoning", "low", 5000)
    session.setMode("code", 5000)
    check session.getModes().get().currentModeId == "code"
    discard session.setConfigOption("model", "fast", 5000)
    discard session.prompt("change", 5000)
    check session.getConfigOptions()[0].currentValue.stringValue == "large"

  test "legacy acknowledgements cannot overwrite newer mode notifications":
    let capture = newCapture()
    defer: freeCapture(capture)
    let client = connect(capture, "legacy-race")
    defer: client.close()
    let session = client.newSession(getTempDir(), timeoutMs = 5000)
    session.setMode("code", 5000)
    check session.getModes().get().currentModeId == "ask"

  test "config-only, legacy-only and minimal peers expose only supported APIs":
    for style in ["config", "legacy", "minimal"]:
      let capture = newCapture()
      defer: freeCapture(capture)
      let client = connect(capture, style)
      defer: client.close()
      let session = client.newSession(getTempDir(), timeoutMs = 5000)
      if style == "config":
        check session.getModes().isNone
        discard session.setConfigOption("enabled", true, 5000)
        expect AcpRpcError: session.setMode("code", 5000)
      elif style == "legacy":
        check session.getConfigOptions().len == 0
        session.setMode("code", 5000)
        check session.getModes().get().currentModeId == "code"
        expect AcpRpcError: discard session.setConfigOption("model", "large", 5000)
      else:
        expect AcpProtocolError: discard client.listSessions(timeoutMs = 5000)
        expect AcpProtocolError: discard client.resumeSession(session.id, getTempDir(), timeoutMs = 5000)
        expect AcpProtocolError: session.closeSession(5000)

  test "one-page listing, metadata patches, close, resume and history replay":
    let capture = newCapture()
    defer: freeCapture(capture)
    let client = connect(capture)
    defer: client.close()
    let first = client.newSession(getTempDir(), timeoutMs = 5000)
    let second = client.newSession(getTempDir(), timeoutMs = 5000)
    let page = client.listSessions(timeoutMs = 5000)
    check page.sessions.len == 1
    check page.nextCursor.isSome
    let next = client.listSessions(cursor = page.nextCursor, timeoutMs = 5000)
    check next.sessions[0].sessionId == first.id
    check next.nextCursor.isNone
    check client.listSessions(cwd = some("/no-such-directory"), timeoutMs = 5000).sessions.len == 0
    expect AcpRpcError: discard client.listSessions(cursor = some("bad"), timeoutMs = 5000)
    discard first.prompt("metadata", 5000)
    check first.getSessionInfo().get().title.isNone
    check first.getSessionInfo().get().updatedAt.get() == "2026-11-13T00:00:00Z"
    let alias = first
    first.closeSession(5000)
    alias.closeSession(5000)
    expect AcpRpcError: discard alias.startPrompt(@[textBlock("closed")])
    discard second.prompt("other session", 5000)
    let before = capture.captured()
    let resumed = client.resumeSession(first.id, getTempDir(), timeoutMs = 5000)
    check capture.captured() == before
    discard alias.prompt("reopened alias", 5000)
    check capture.captured().endsWith("closed=1")
    resumed.closeSession(5000)
    discard client.loadSession(first.id, getTempDir(), timeoutMs = 5000)
    check capture.captured().endsWith("history")

  test "management works with saturated workers and close settles queued prompts":
    let capture = newCapture()
    defer: freeCapture(capture)
    let client = connect(capture)
    defer: client.close()
    let first = client.newSession(getTempDir(), timeoutMs = 5000)
    let second = client.newSession(getTempDir(), timeoutMs = 5000)
    var running = first.startPrompt(@[textBlock("slow")])
    for attempt in 0 ..< 1000:
      if capture.captured() == "started": break
      sleep(5)
    check capture.captured() == "started"
    var queued = second.startPrompt(@[textBlock("queued")])
    discard first.setConfigOption("enabled", true, 5000)
    second.closeSession(5000)
    check queued.waitForPrompt(5000).stopReason == cancelled
    first.closeSession(5000)
    check running.waitForPrompt(5000).stopReason == cancelled
    let reopened = client.resumeSession(first.id, getTempDir(), timeoutMs = 5000)
    discard reopened.prompt("again", 5000)

  test "close cancels a pending permission without blocking callback dispatch":
    let capture = newCapture()
    defer: freeCapture(capture)
    let client = connect(capture)
    defer: client.close()
    let session = client.newSession(getTempDir(), timeoutMs = 5000)
    var turn = session.startPrompt(@[textBlock("permission")])
    var decisions = 0
    for attempt in 0 ..< 1000:
      withLock capture.lock: decisions = capture.decisions
      if decisions > 0: break
      sleep(5)
    check decisions == 1
    session.closeSession(5000)
    check turn.waitForPrompt(5000).stopReason == cancelled

  test "raw peers without boolean support see filtered catalogs":
    let process = startProcess(absolutePath("build/session-agent"), options = {})
    defer:
      process.inputStream.close()
      discard process.waitForExit(5000)
      process.close()
    for request in [
      %*{"jsonrpc":"2.0", "id":1, "method":"initialize", "params":{"protocolVersion":1, "clientCapabilities":{}}},
      %*{"jsonrpc":"2.0", "id":2, "method":"session/new", "params":{"cwd":getTempDir(), "mcpServers":[]}}]:
      process.inputStream.writeLine($request)
      process.inputStream.flush()
      let response = parseJson(process.outputStream.readLine())
      if request["id"].getInt() == 2:
        check response["result"]["configOptions"].len == 2
    process.inputStream.writeLine($(%*{"jsonrpc":"2.0", "id":3,
      "method":"session/set_config_option", "params":{"sessionId":"session-1",
        "configId":"enabled", "type":"boolean", "value":true}}))
    process.inputStream.flush()
    check parseJson(process.outputStream.readLine())["error"]["code"].getInt() == InvalidParams
    process.inputStream.writeLine($(%*{"jsonrpc":"2.0", "id":4,
      "method":"session/prompt", "params":{"sessionId":"session-1",
        "prompt":[{"type":"text", "text":"change"}]}}))
    process.inputStream.flush()
    let notification = parseJson(process.outputStream.readLine())
    check notification["params"]["update"]["configOptions"].len == 2
    discard process.outputStream.readLine() # The prompt's message chunk.
    check parseJson(process.outputStream.readLine())["id"].getInt() == 4
