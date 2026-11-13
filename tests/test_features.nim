import
  std/[json, locks, options, os, osproc, streams, unittest],
  acport,
  acport/connection

type Capture = object
  lock: Lock
  text, schema: SharedText
  forms, completions, notifications, commandCount: int
  used: uint64
  action: ElicitationAction
  hold, waitCancellation, requestScoped: bool
  client: AcpClient

proc collect(update: SessionUpdate, data: pointer) {.gcsafe.} =
  ## Read the latest cache inside callbacks and transfer only owned shared text.
  let state = cast[ptr Capture](data)
  if update.parseAvailableCommandsUpdate().isSome:
    let count = AcpSession(client: state.client, id: update.sessionId).getAvailableCommands().len
    withLock state.lock: state.commandCount = count
  if update.parseUsageUpdate().isSome:
    let used = AcpSession(client: state.client, id: update.sessionId).getUsage().get().used
    withLock state.lock: state.used = used
  if update.kind == agentMessageChunk:
    withLock state.lock:
      let text = localText(state.text) & update.content.text
      freeText(state.text)
      state.text = sharedText(text)

proc elicit(context: RequestContext, request: ElicitationRequest, data: pointer): ElicitationResponse {.gcsafe.} =
  ## Make deterministic test decisions while cooperating with close/cancellation.
  let state = cast[ptr Capture](data)
  var action: ElicitationAction
  var waitCancellation: bool
  withLock state.lock:
    inc state.forms
    state.requestScoped = request.scope == requestElicitationScope
    freeText(state.schema)
    state.schema = sharedText($(if request.requestedSchema == nil: newJNull() else: request.requestedSchema))
    action = state.action
    waitCancellation = state.waitCancellation
  while true:
    var hold: bool
    withLock state.lock: hold = state.hold
    if context.isCancelled(): return ElicitationResponse(action: cancelElicitation)
    if not hold and not waitCancellation: break
    sleep(5)
  result = ElicitationResponse(action: action)
  if action == acceptElicitation and request.mode == formElicitation: result.content = %*{"color":"cobalt"}

proc completed(completion: ElicitationComplete, data: pointer) {.gcsafe.} =
  ## Count only completions admitted by the runtime's correlation registry.
  let state = cast[ptr Capture](data)
  withLock state.lock: inc state.completions

proc extension(context: RequestContext, name: string, params: JsonNode, data: pointer): JsonNode {.gcsafe.} =
  ## Answer a nested custom request without rewriting opaque JSON.
  if name != "_client_echo": raise rpcError(MethodNotFound, "Unknown client extension")
  params

proc notification(name: string, params: JsonNode, data: pointer) {.gcsafe.} =
  ## Observe custom notifications on the ordered callback thread.
  let state = cast[ptr Capture](data)
  withLock state.lock: inc state.notifications

proc newCapture(): ptr Capture =
  ## Allocate callback state containing only POD values and shared buffers.
  result = cast[ptr Capture](allocShared0(sizeof(Capture)))
  initLock(result.lock)

proc freeCapture(state: ptr Capture) =
  ## Free callback state only after connection threads have joined.
  freeText(state.text)
  freeText(state.schema)
  deinitLock(state.lock)
  deallocShared(state)

proc counts(state: ptr Capture): tuple[forms, completions, notifications: int] =
  ## Copy synchronized counters for bounded assertions.
  withLock state.lock: result = (state.forms, state.completions, state.notifications)

proc text(state: ptr Capture): string =
  ## Copy accumulated prompt output to the asserting thread.
  withLock state.lock: result = localText(state.text)

proc connect(state: ptr Capture, form = true, url = true, raw = false): AcpClient =
  ## Start an ACPort or independent wire fixture with explicit mode support.
  result = newAcpClient("features", "1", ClientHandlers(onUpdate: collect,
    onExtensionRequest: extension, onExtensionNotification: notification,
    onElicitationForm: if form: elicit else: nil, onElicitationUrl: if url: elicit else: nil,
    onElicitationComplete: completed, userData: state))
  state.client = result
  result.connect(absolutePath(if raw: "build/features-raw" else: "build/features-agent"))
  let info = result.initialize(5000, extensionCapabilities = %*{"client-feature":true}, meta = %*{"client":1})
  if not raw:
    doAssert info.agentCapabilities["_meta"] == %*{"feature":true}
    doAssert info.meta == %*{"agent":1}

suite "feature payloads":
  test "command and usage codecs preserve nested metadata and unknown fields":
    let commands = %*[{"name":"inspect", "description":"Inspect", "input":{"hint":"path", "_meta":{"x":1}}, "_meta":{"y":2}}]
    check parseAvailableCommands(commands).toJsonNode() == commands
    check parseAvailableCommands(commands)[0].input.get().hint == "path"
    check parseAvailableCommands(newJArray()).len == 0
    let usage = %*{"used":12, "size":200, "cost":{"amount":0.25, "currency":"credits", "_meta":{"x":1}}, "extra":true}
    check parseUsage(usage).toJsonNode() == usage
    check parseUsage(usage).cost.get().currency == "credits"
    check parseUsage(%*{"used":0, "size":0}).cost.isNone
    expect AcpRpcError: discard parseUsage(%*{"used": -1, "size":20})
    expect AcpRpcError: discard parseUsage(%*{"used":1.5, "size":20})
    expect AcpRpcError: discard parseUsage(%*{"size":20})
    check usageUpdate("s", UsageUpdate(used: 0, size: 0)).kind == unknownUpdate

  test "elicitation scopes and opaque schemas round trip":
    for id in [%7, %"string-id", newJNull()]:
      let wire = %*{"mode":"form", "requestId":id, "message":"Question",
        "requestedSchema":{"type":"object", "custom":{"untouched":true}}, "_meta":{"x":1}}
      let request = parseElicitationRequest(wire)
      check request.scope == requestElicitationScope
      check request.requestId == id
      check request.toJsonNode() == wire
    let wire = %*{"mode":"url", "sessionId":"s", "toolCallId":"t", "message":"Question", "url":"https://example.invalid", "elicitationId":"e"}
    check parseElicitationRequest(wire).toolCallId.get() == "t"
    check parseElicitationRequest(wire).toJsonNode() == wire
    expect AcpRpcError: discard parseElicitationRequest(%*{"sessionId":"s", "message":"Missing mode"})
    expect AcpRpcError:
      discard parseElicitationRequest(%*{"mode":"form", "sessionId":"s", "requestId":1, "message":"Both", "requestedSchema":{}})
    let future = %*{"mode":"future", "requestId":1, "message":"Future", "extra":[1]}
    check parseElicitationRequest(future).toJsonNode() == future

  test "decisions preserve future actions and validate only ACP content shapes":
    for action in ["accept", "decline", "cancel", "_future"]:
      let wire = %*{"action":action, "content":{"value":"opaque"}, "_meta":{"x":1}}
      check parseElicitationResponse(wire).toJsonNode() == wire
    check parseElicitationResponse(%*{"action":"_future"}).action == unknownElicitationAction
    check parseElicitationResponse(%*{"action":"decline", "content":{"secret":{}}}).content == nil
    expect AcpRpcError: discard parseElicitationResponse(%*{"action":"accept", "content":{"nested":{}}})
    expect AcpRpcError: discard parseElicitationResponse(%*{"action":"accept", "content":{"items":[1]}})
    discard parseElicitationResponse(%*{"action":"accept", "content":{"items":["x"], "b":true, "n":1.5}})

suite "extensions and live event state":
  test "both directions preserve payloads, metadata, errors and notification hygiene":
    let state = newCapture()
    defer: freeCapture(state)
    let client = connect(state)
    defer: client.close()
    let payload = %*{"nested":[true, 7], "_meta":{"opaque":true}}
    check client.requestExtension("_echo", payload, 5000) == payload
    check client.requestExtension("_echo", %*[1, false], 5000) == %*[1, false]
    let caps = client.requestExtension("_caps", newJObject(), 5000)
    check caps["clientCapabilities"]["_meta"] == %*{"client-feature":true}
    check caps["_meta"] == %*{"client":1}
    expect ValueError: discard client.requestExtension("session/new", payload)
    expect ValueError: client.notifyExtension("_", payload)
    expect AcpRpcError: discard client.requestExtension("_missing", payload, 5000)
    try:
      discard client.requestExtension("_rpc-error", payload, 5000)
      check false
    except AcpRpcError as error:
      check error.code == -32001
      check error.data == %*{"detail":[1, true]}
    client.notifyExtension("_note", payload)
    var observed = 0
    for attempt in 0 ..< 1000:
      observed = client.requestExtension("_count", newJObject(), 5000).getInt()
      if observed > 0: break
      sleep(5)
    check observed == 1
    let session = client.newSession(getTempDir(), timeoutMs = 5000)
    discard session.prompt("extension", 5000)
    check state.text() == "{\"nested\":[true,7]}"
    check state.counts().notifications == 1
    expect AcpTimeoutError: discard client.requestExtension("_wait", newJObject(), 25)
    check client.requestExtension("_echo", %true, 5000).getBool()

  test "catalog replacement, unreported/zero usage and owned callback snapshots":
    let state = newCapture()
    defer: freeCapture(state)
    let client = connect(state)
    defer: client.close()
    let session = client.newSession(getTempDir(), timeoutMs = 5000)
    check session.getAvailableCommands().len == 1
    check session.getUsage().get().used == 12
    check session.getUsage().get().cost.get().amount == 0.25
    var commands = session.getAvailableCommands()
    commands[0].raw["name"] = %"mutated"
    check session.getAvailableCommands()[0].name == "inspect"
    discard session.prompt("events", 5000)
    check session.getAvailableCommands().len == 0
    check session.getUsage().get().used == 0
    check session.getUsage().get().cost.isNone
    withLock state.lock:
      check state.commandCount == 0
      check state.used == 0
    session.closeSession(5000)
    check session.getUsage().get().size == 0

suite "elicitation runtime":
  test "client shutdown cancels a pending interaction and keeps its prompt collectible":
    let state = newCapture()
    defer: freeCapture(state)
    let client = connect(state)
    withLock state.lock: state.waitCancellation = true
    let session = client.newSession(getTempDir(), timeoutMs = 5000)
    var turn = session.startPrompt(@[textBlock("slow-form")])
    for attempt in 0 ..< 1000:
      if state.counts().forms > 0: break
      sleep(5)
    check state.counts().forms == 1
    client.close()
    check turn.isReady()
    expect AcpTransportError: discard turn.waitForPrompt(5000)

  test "request scope works before sessions and callbacks select form decisions":
    let state = newCapture()
    defer: freeCapture(state)
    let client = connect(state)
    defer: client.close()
    client.authenticate("form-auth", 5000)
    withLock state.lock:
      check state.requestScoped
      check parseJson(localText(state.schema))["_meta"] == %*{"schema":"opaque"}
    let session = client.newSession(getTempDir(), timeoutMs = 5000)
    for action in [acceptElicitation, declineElicitation, cancelElicitation]:
      withLock state.lock: state.action = action
      check session.prompt("form", 5000).stopReason == endTurn
    check state.counts().forms == 4

  test "URL IDs are connection-owned, unique while outstanding and cleared on close":
    let state = newCapture()
    defer: freeCapture(state)
    let client = connect(state)
    defer: client.close()
    let session = client.newSession(getTempDir(), timeoutMs = 5000)
    discard session.prompt("url", 5000)
    check state.counts().completions == 1
    discard session.prompt("url-background", 5000)
    check client.requestExtension("_duplicate", %*{"sessionId":session.id, "elicitationId":"flow-" & session.id}, 5000).getBool()
    discard client.requestExtension("_complete", %*{"elicitationId":"flow-" & session.id}, 5000)
    check state.counts().completions == 2
    expect AcpRpcError: discard client.requestExtension("_complete", %*{"elicitationId":"unknown"}, 5000)
    withLock state.lock: state.action = declineElicitation
    discard session.prompt("url-background", 5000)
    expect AcpRpcError: discard client.requestExtension("_complete", %*{"elicitationId":"flow-" & session.id}, 5000)
    withLock state.lock: state.action = acceptElicitation
    discard session.prompt("url-background", 5000)
    session.closeSession(5000)
    expect AcpRpcError: discard client.requestExtension("_complete", %*{"elicitationId":"flow-" & session.id}, 5000)

  test "early completion waits for consent and ignores duplicate/unknown notifications":
    for action in [acceptElicitation, declineElicitation, cancelElicitation]:
      let state = newCapture()
      defer: freeCapture(state)
      state.hold = true
      state.action = action
      let client = connect(state, raw = true)
      defer: client.close()
      defer:
        withLock state.lock: state.hold = false
      let session = client.newSession(getTempDir(), timeoutMs = 5000)
      check session.getUsage().isNone
      var turn = session.startPrompt(@[textBlock("early-url")])
      for attempt in 0 ..< 1000:
        if state.text() == "received" and state.counts().forms == 1: break
        sleep(5)
      check state.text() == "received"
      check state.counts().forms == 1
      check state.counts().completions == 0
      withLock state.lock: state.hold = false
      check turn.waitForPrompt(5000).stopReason == endTurn
      check state.counts().completions == (if action == acceptElicitation: 1 else: 0)

  test "only installed modes are advertised and unsupported calls fail":
    for form in [false, true]:
      let state = newCapture()
      defer: freeCapture(state)
      let client = connect(state, form = form, url = false)
      defer: client.close()
      let caps = client.requestExtension("_caps", newJObject(), 5000)["clientCapabilities"]
      if form: check caps["elicitation"] == %*{"form":{}}
      else: check not caps.hasKey("elicitation")
      let session = client.newSession(getTempDir(), timeoutMs = 5000)
      expect AcpRpcError: discard session.prompt("url", 5000)
      if not form:
        expect AcpRpcError: discard session.prompt("form", 5000)
    block:
      let client = newAcpClient("no-elicitation", "1")
      defer: client.close()
      client.connect(absolutePath("build/features-raw"), @["unsupported"])
      discard client.initialize(5000)
      let session = client.newSession(getTempDir(), timeoutMs = 5000)
      check session.prompt("unsupported", 5000).stopReason == endTurn

  test "close and parent deadlines cancel blocked UI handlers without losing the connection":
    let state = newCapture()
    defer: freeCapture(state)
    let client = connect(state)
    defer: client.close()
    state.waitCancellation = true
    let session = client.newSession(getTempDir(), timeoutMs = 5000)
    var turn = session.startPrompt(@[textBlock("slow-form")])
    for attempt in 0 ..< 1000:
      if state.counts().forms > 0: break
      sleep(5)
    check state.counts().forms == 1
    session.closeSession(5000)
    check turn.waitForPrompt(5000).stopReason == cancelled
    expect AcpTimeoutError: client.authenticate("form-auth", 300)
    check client.requestExtension("_echo", %"alive", 5000).getStr() == "alive"

  test "raw caller IDs, unprefixed methods and notification response hygiene":
    let process = startProcess(absolutePath("build/features-agent"), options = {})
    defer:
      process.inputStream.close()
      discard process.waitForExit(5000)
      process.close()
    process.inputStream.writeLine($(%*{"jsonrpc":"2.0", "id":0, "method":"initialize",
      "params":{"protocolVersion":1, "clientCapabilities":{"elicitation":{"form":{}}}}}))
    process.inputStream.flush()
    discard process.outputStream.readLine()
    for id in [%"string-id", newJNull()]:
      let request = %*{"jsonrpc":"2.0", "id":id, "method":"authenticate", "params":{"methodId":"form-auth"}}
      process.inputStream.writeLine($request)
      process.inputStream.flush()
      let elicitation = parseJson(process.outputStream.readLine())
      check elicitation["method"].getStr() == "elicitation/create"
      check elicitation["params"]["requestId"] == id
      process.inputStream.writeLine($(%*{"jsonrpc":"2.0", "id":elicitation["id"], "result":{"action":"accept"}}))
      process.inputStream.flush()
      let response = parseJson(process.outputStream.readLine())
      check response["id"] == id
    for methodName in ["_custom_notification", "unknown_notification"]:
      process.inputStream.writeLine($(%*{"jsonrpc":"2.0", "method":methodName, "params":{}}))
    process.inputStream.writeLine($(%*{"jsonrpc":"2.0", "id":"last", "method":"not_an_extension", "params":{}}))
    process.inputStream.flush()
    let last = parseJson(process.outputStream.readLine())
    check last["id"].getStr() == "last"
    check last["error"]["code"].getInt() == MethodNotFound
