import
  std/[atomics, json, monotimes, os, strutils, times],
  acport/[connection, protocol]

type Capture = object
  updates: Atomic[int]
  logs: Atomic[int]
  hold: Atomic[bool]
  entered: Atomic[bool]
  unicode: Atomic[bool]

proc handleRequest(context: RequestContext, methodName: string,
    params: JsonNode): JsonNode {.gcsafe.} =
  ## Supplies deterministic bidirectional requests without external processes.
  case methodName
  of "_echo":
    result = params
  of "session/request_permission":
    result = %*{"outcome": {"outcome": "cancelled"}}
  of "_blocking":
    while not context.isCancelled():
      sleep(1)
    result = %*{"cancelled": true}
  else:
    raise rpcError(MethodNotFound, "Unsupported fixture method")

proc handleNotification(context: RequestContext, methodName: string,
    params: JsonNode) {.gcsafe.} =
  ## Records ordered callbacks using only shared atomic state across threads.
  let capture = cast[ptr Capture](context.userData())
  if methodName == "session/update":
    capture.entered.store(true)
    while capture.hold.load():
      sleep(1)
    if params["update"]["content"]["text"].getStr() == "Hello, 世界.":
      capture.unicode.store(true)
    discard capture.updates.fetchAdd(1)

proc handleLog(data: pointer, text: string) {.gcsafe.} =
  ## Counts diagnostic delivery independently of JSON-RPC framing.
  let capture = cast[ptr Capture](data)
  if text == "diagnostic":
    discard capture.logs.fetchAdd(1)

proc waitReady(pending: PendingRequest) =
  ## Bounds completion polling while preserving the normal callback barrier.
  let started = getMonoTime()
  while not pending.isReady():
    doAssert (getMonoTime() - started).inSeconds < 5
    sleep(1)

proc waitOutput(peer: Connection): JsonNode =
  ## Collects one fixture response without treating temporary silence as EOF.
  let started = getMonoTime()
  while true:
    let bytes = peer.takeOutgoing()
    if bytes.len > 0:
      return parseJson(bytes.strip())
    doAssert (getMonoTime() - started).inSeconds < 5
    sleep(1)

proc notification(text: string): string =
  ## Encodes a raw update independently of the ACPort protocol codecs.
  $(%*{
    "jsonrpc": "2.0", "method": "session/update",
    "params": {"sessionId": "session", "update": {
      "sessionUpdate": "agent_message_chunk",
      "content": {"type": "text", "text": text}
    }}
  }) & "\n"

proc testDrivenRequests() =
  ## Checks fragmented bytes, response correlation, callbacks, and rich IDs.
  echo "Testing externally driven ACP request dispatch"
  var capture: Capture
  let peer = newDrivenConnection(
    handleRequest, handleNotification, addr capture, handleLog
  )
  defer:
    capture.hold.store(false)
    peer.close()
  let pending = peer.startRequest("_request", %*{"literal": "' $() `世界`"})
  let request = parseJson(peer.takeOutgoing().strip())
  doAssert request["method"].getStr() == "_request"
  doAssert request["params"]["literal"].getStr() == "' $() `世界`"
  peer.feed("")
  doAssert not pending.isReady()
  let response = $(%*{
    "jsonrpc": "2.0", "id": request["id"], "result": {"answer": "世界"}
  }) & "\n"
  for character in response:
    peer.feed($character)
  pending.waitReady()
  doAssert pending.waitResponse()["answer"].getStr() == "世界"

  for character in notification("Hello, 世界."):
    peer.feed($character)
  peer.feedError("diagnostic")
  let started = getMonoTime()
  while capture.updates.load() != 1 or capture.logs.load() != 1:
    doAssert (getMonoTime() - started).inSeconds < 5
    sleep(1)
  doAssert capture.unicode.load()

  peer.feed("{\"jsonrpc\":\"2.0\",\"id\":\"permission-1\"," &
    "\"method\":\"session/request_permission\",\"params\":{}}\n")
  let permission = peer.waitOutput()
  doAssert permission["id"].getStr() == "permission-1"
  doAssert permission["result"]["outcome"]["outcome"].getStr() == "cancelled"
  peer.feed("{\"jsonrpc\":\"2.0\",\"id\":44," &
    "\"method\":\"not_supported\",\"params\":{}}\n")
  doAssert peer.waitOutput()["error"]["code"].getInt() == MethodNotFound

proc testCallbackBarrier() =
  ## Keeps a response pending until preceding update callbacks are delivered.
  echo "Testing driven callback ordering"
  var capture: Capture
  capture.hold.store(true)
  let peer = newDrivenConnection(nil, handleNotification, addr capture)
  defer:
    capture.hold.store(false)
    peer.close()
  let pending = peer.startRequest("_request", %*{})
  let request = parseJson(peer.takeOutgoing().strip())
  peer.feed(notification("Hello, 世界."))
  let started = getMonoTime()
  while not capture.entered.load():
    doAssert (getMonoTime() - started).inSeconds < 5
    sleep(1)
  peer.feed($( %*{"jsonrpc": "2.0", "id": request["id"], "result": {}}) & "\n")
  doAssert not pending.isReady()
  capture.hold.store(false)
  pending.waitReady()
  discard pending.waitResponse()
  doAssert capture.updates.load() == 1

proc testCancellation() =
  ## Cancels an incoming worker request without requiring a pipe reader.
  echo "Testing driven request cancellation"
  let peer = newDrivenConnection(handleRequest, nil)
  defer: peer.close()
  peer.feed("{\"jsonrpc\":\"2.0\",\"id\":7," &
    "\"method\":\"_blocking\",\"params\":{\"sessionId\":\"session\"}}\n")
  peer.feed("{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\"," &
    "\"params\":{\"sessionId\":\"session\"}}\n")
  let response = peer.waitOutput()
  doAssert response["id"].getInt() == 7
  doAssert response["result"]["cancelled"].getBool()

proc testEofAndClose() =
  ## Settles pending handles on clean EOF, truncated EOF, and owner shutdown.
  echo "Testing driven EOF and pending-handle lifetime"
  for truncated in [false, true]:
    let peer = newDrivenConnection(nil, nil)
    let pending = peer.startRequest("_request", %*{})
    discard peer.takeOutgoing()
    if truncated:
      peer.feed("{\"jsonrpc\":")
    peer.endInput()
    doAssert pending.isReady()
    var failed = false
    try:
      discard pending.waitResponse()
    except AcpProtocolError:
      doAssert truncated
      failed = true
    except AcpTransportError:
      doAssert not truncated
      failed = true
    doAssert failed
    peer.close()

  let peer = newDrivenConnection(nil, nil)
  let pending = peer.startRequest("_request", %*{})
  peer.close()
  doAssert pending.isReady()
  var closed = false
  try:
    discard pending.waitResponse()
  except AcpTransportError:
    closed = true
  doAssert closed

  let finished = newDrivenConnection(nil, nil)
  defer: finished.close()
  let completed = finished.startRequest("_request", %*{})
  let request = parseJson(finished.takeOutgoing().strip())
  finished.feed($( %*{
    "jsonrpc": "2.0", "id": request["id"], "result": {"done": true}
  }) & "\n")
  finished.endInput()
  doAssert completed.waitResponse()["done"].getBool()

proc testLimitsAndParseErrors() =
  ## Fails bounded buffers explicitly and preserves standard parse errors.
  echo "Testing driven buffer limits and malformed JSON"
  block:
    let peer = newDrivenConnection(nil, nil, maxMessageBytes = 64)
    defer: peer.close()
    peer.feed("not json\n")
    doAssert parseJson(peer.takeOutgoing().strip())["error"]["code"].getInt() == ParseError
    var bounded = false
    try:
      peer.feed(repeat('x', 65))
    except AcpProtocolError:
      bounded = true
    doAssert bounded
  block:
    let peer = newDrivenConnection(nil, nil, maxOutgoingBytes = 80)
    defer: peer.close()
    peer.notify("_event", %*{})
    var bounded = false
    try:
      peer.notify("_event", %*{})
    except AcpTransportError:
      bounded = true
    doAssert bounded
  block:
    var capture: Capture
    capture.hold.store(true)
    let peer = newDrivenConnection(
      nil, handleNotification, addr capture, maxQueuedBytes = 300
    )
    defer:
      capture.hold.store(false)
      peer.close()
    peer.feed(notification("Hello, 世界."))
    let started = getMonoTime()
    while not capture.entered.load():
      doAssert (getMonoTime() - started).inSeconds < 5
      sleep(1)
    var bounded = false
    for i in 0 ..< 10:
      try:
        peer.feed(notification("Hello, 世界."))
      except AcpTransportError:
        bounded = true
        break
    doAssert bounded

testDrivenRequests()
testCallbackBarrier()
testCancellation()
testEofAndClose()
testLimitsAndParseErrors()
echo "Externally driven ACP tests passed."
