import
  std/[atomics, os, strutils, unittest],
  acport

type Capture = object
  count: Atomic[int]
  ordered: Atomic[bool]

proc create(context: RequestContext, request: SessionRequest, data: pointer): SessionResponse {.gcsafe.} =
  ## Supply a deterministic session for bounded delivery tests.
  SessionResponse(sessionId: "delivery")

proc generate(context: RequestContext, request: PromptRequest, data: pointer): PromptResponse {.gcsafe.} =
  ## Produce more history than the client queue can retain at once.
  for index in 0..<512:
    if context.isCancelled(): return PromptResponse(stopReason: cancelled)
    context.sendUpdate(SessionUpdate(sessionId: request.sessionId, kind: agentMessageChunk,
      content: textBlock($index & ":" & repeat('x', 64 * 1024))))
  PromptResponse(stopReason: endTurn)

proc receive(update: SessionUpdate, data: pointer) {.gcsafe.} =
  ## Slow the consumer enough to force notification backpressure.
  let capture = cast[ptr Capture](data)
  let index = parseInt(update.content.text.split(':', 1)[0])
  if index != capture.count.load(): capture.ordered.store(false)
  discard capture.count.fetchAdd(1)
  sleep(1)

proc client(capture: ptr Capture, frameLimit = 128 * 1024): AcpClient =
  ## Run the real stdio transport with a queue smaller than the generated history.
  result = newAcpClient("delivery", "1", ClientHandlers(onUpdate: receive, userData: capture),
    ClientOptions(maxMessageBytes: frameLimit, maxQueuedBytes: 128 * 1024))
  result.connect(getAppFilename(), @["--delivery-agent"])
  discard result.initialize(5000)

if "--delivery-agent" in commandLineParams():
  let agent = newAcpAgent("delivery-fixture", "1", AgentHandlers(onNewSession: create, onPrompt: generate))
  agent.runStdioAgent()
  agent.close()
else:
  suite "bounded notification delivery":
    test "backpressure preserves every ordered update and prompt completion barrier":
      var capture: Capture
      capture.ordered.store(true)
      let peer = client(addr capture)
      defer: peer.close()
      let session = peer.newSession(getCurrentDir(), timeoutMs = 5000)
      check session.prompt("burst", 30_000).stopReason == endTurn
      check capture.count.load() == 512
      check capture.ordered.load()
    test "oversized frames fail explicitly":
      var capture: Capture
      let peer = client(addr capture, 4096)
      defer: peer.close()
      let session = peer.newSession(getCurrentDir(), timeoutMs = 5000)
      expect AcpProtocolError:
        discard session.prompt("burst", 5000)
    test "closing a saturated connection settles pending work":
      var capture: Capture
      let peer = client(addr capture)
      let session = peer.newSession(getCurrentDir(), timeoutMs = 5000)
      var prompt = session.startPrompt(@[textBlock("burst")])
      while capture.count.load() < 4: sleep(5)
      peer.close()
      check prompt.isReady()
      expect AcpTransportError:
        discard prompt.waitForPrompt(5000)
