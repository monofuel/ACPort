import
  std/[atomics, json, locks, monotimes, os, strutils, times],
  acport,
  acport/connection

const ImageDataBytes = 3 * 1024 * 1024

type Capture = object
  client: AcpClient
  stop: Atomic[bool]
  authAdvertised: Atomic[bool]
  terminalInvoked: Atomic[bool]
  updates: Atomic[int]
  logs: Atomic[int]
  images: Atomic[int]
  imageBytes: Atomic[int]
  invalidImage: Atomic[bool]
  lock: Lock
  text, error: SharedText

proc imageData(): string =
  ## Supplies deterministic base64 data larger than the former outgoing limit.
  "QUJD".repeat(ImageDataBytes div 4)

proc update(update: SessionUpdate, data: pointer) {.gcsafe.} =
  ## Transfers callback text as an owned buffer before signaling delivery.
  let capture = cast[ptr Capture](data)
  if update.kind == agentMessageChunk:
    if update.content.kind == imageContent:
      if update.content.data != imageData() or
        update.content.mimeType != "image/png":
          capture.invalidImage.store(true)
      discard capture.images.fetchAdd(1)
      discard capture.imageBytes.fetchAdd(update.content.data.len)
    else:
      withLock capture.lock:
        freeText(capture.text)
        capture.text = sharedText(update.content.text)
    discard capture.updates.fetchAdd(1)

proc log(data: pointer, text: string) {.gcsafe.} =
  ## Counts separate diagnostics without treating them as protocol input.
  if text == "fixture diagnostic":
    discard cast[ptr Capture](data).logs.fetchAdd(1)

proc terminalAuth(invocation: TerminalAuthInvocation,
    data: pointer): TerminalExitStatus {.gcsafe.} =
  ## Records any unsupported attempt to launch an interactive authentication.
  cast[ptr Capture](data).terminalInvoked.store(true)

proc respond(capture: ptr Capture, request: JsonNode) =
  ## Acts as a deterministic peer while keeping JSON local to this thread.
  let client = capture.client
  var value: JsonNode
  case request["method"].getStr()
  of "initialize":
    let capabilities = request["params"]["clientCapabilities"]
    capture.authAdvertised.store(capabilities.hasKey("auth"))
    value = %*{
      "protocolVersion": 1,
      "agentCapabilities": {"promptCapabilities": {"image": true}},
      "authMethods": [{"id": "interactive", "name": "Login",
        "type": "terminal", "args": []}]
    }
  of "session/new":
    doAssert request["params"]["cwd"].getStr().isAbsolute()
    value = %*{"sessionId": "driven-session"}
  of "session/prompt":
    doAssert request["params"]["sessionId"].getStr() == "driven-session"
    let content = request["params"]["prompt"][0]
    var response: JsonNode
    if content["type"].getStr() == "image":
      doAssert content["mimeType"].getStr() == "image/png"
      doAssert content["data"].getStr() == imageData()
      response = content
    else:
      doAssert content["text"].getStr() == "Hello"
      response = %*{"type": "text", "text": "Hello, 世界."}
    client.feed($( %*{
      "jsonrpc": "2.0", "method": "session/update",
      "params": {"sessionId": "driven-session", "update": {
        "sessionUpdate": "agent_message_chunk",
        "content": response
      }}
    }) & "\n")
    value = %*{"stopReason": "end_turn"}
  of "_eof":
    client.endInput()
    capture.stop.store(true)
    return
  else:
    raise newException(ValueError, "Unexpected fixture request")
  let response = $(%*{
    "jsonrpc": "2.0", "id": request["id"], "result": value
  }) & "\n"
  for character in response:
    client.feed($character)

proc pump(capture: ptr Capture) {.thread.} =
  ## Drives caller-owned I/O while public synchronous API calls run elsewhere.
  try:
    let started = getMonoTime()
    while not capture.stop.load():
      if (getMonoTime() - started).inSeconds > 10:
        raise newException(ValueError, "Fixture pump timed out")
      let outgoing = capture.client.takeOutgoing()
      for line in outgoing.splitLines():
        if line.len > 0:
          capture.respond(parseJson(line))
      sleep(1)
  except CatchableError as error:
    withLock capture.lock:
      capture.error = sharedText(error.msg)

template rejects(errorType: typedesc, expression: untyped) =
  ## Checks public state guards without relying on implementation details.
  block:
    var rejected = false
    try:
      expression
    except errorType:
      rejected = true
    doAssert rejected

proc testDrivenApi(explicitZero: bool) =
  ## Exercises process-free initialization, callbacks, session turns, and EOF.
  echo "Testing caller-driven public ACP client API"
  var capture: Capture
  initLock(capture.lock)
  let
    handlers = ClientHandlers(
      onUpdate: update,
      onLog: log,
      onTerminalAuth: terminalAuth,
      userData: addr capture
    )
    client =
      if explicitZero:
        newAcpClient("driven-test", "1", handlers,
          ClientOptions(maxMessageBytes: 0, maxQueuedBytes: 0))
      else:
        newAcpClient("driven-test", "1", handlers)
  capture.client = client
  defer:
    client.close()
    freeText(capture.text)
    freeText(capture.error)
    deinitLock(capture.lock)

  rejects(AcpTransportError): client.feed("")
  rejects(AcpTransportError): discard client.takeOutgoing()
  rejects(AcpTransportError): client.endInput()
  rejects(ValueError): client.connectDriven(workerThreads = 0)
  client.connectDriven()
  rejects(AcpProtocolError): client.connectDriven()
  rejects(AcpProtocolError): discard client.newSession("/")
  client.feed("")
  client.feedError("fixture diagnostic")
  doAssert client.takeOutgoing() == ""

  var thread: Thread[ptr Capture]
  createThread(thread, pump, addr capture)
  defer:
    capture.stop.store(true)
    joinThread(thread)
    doAssert localText(capture.error) == "", localText(capture.error)

  let initialized = client.initialize(2000)
  doAssert initialized.protocolVersion == 1
  doAssert not capture.authAdvertised.load()
  rejects(AcpProtocolError): discard client.initialize(2000)
  rejects(AcpProtocolError):
    discard client.authenticateTerminal("interactive", 2000)
  doAssert not capture.terminalInvoked.load()
  let session = client.newSession("/", timeoutMs = 2000)
  doAssert session.id == "driven-session"
  doAssert session.prompt("Hello", 2000).stopReason == endTurn
  doAssert capture.updates.load() == 1
  doAssert capture.logs.load() == 1
  withLock capture.lock:
    doAssert localText(capture.text) == "Hello, 世界."
  let image = ContentBlock(
    kind: imageContent, data: imageData(), mimeType: "image/png"
  )
  doAssert session.prompt(@[image], 2000).stopReason == endTurn
  doAssert capture.images.load() == 1
  doAssert capture.imageBytes.load() == ImageDataBytes
  doAssert not capture.invalidImage.load()
  rejects(AcpTransportError):
    discard client.requestExtension("_eof", %*{}, 2000)

proc testDrivenOptions() =
  ## Rejects invalid bounds and leaves failed startup safe to close.
  echo "Testing caller-driven option validation"
  let bounded = newAcpClient("limits", "1",
    options = ClientOptions(maxMessageBytes: -1))
  defer: bounded.close()
  rejects(ValueError): bounded.connectDriven()
  rejects(AcpTransportError): discard bounded.initialize(100)

  when not defined(linux):
    let portable = newAcpClient("portable", "1")
    defer: portable.close()
    rejects(OSError): portable.connect("unused-fixture-command")
    portable.connectDriven()
    portable.feed("")
    doAssert portable.takeOutgoing() == ""

testDrivenApi(false)
testDrivenApi(true)
testDrivenOptions()
