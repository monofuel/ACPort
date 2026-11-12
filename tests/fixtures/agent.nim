import
  std/[json, locks, os, strutils],
  acport

type
  State = object
    lock: Lock
    nextId: int
    requiresAuth, authenticated: bool

proc createSession(context: RequestContext, request: SessionRequest,
    userData: pointer): SessionResponse {.gcsafe.} =
  ## Allocate and persist a session for load/replay tests.
  if request.cwd.endsWith("slow-creation"):
    context.sendUpdate(SessionUpdate(sessionId: "setup", kind: agentMessageChunk,
      content: textBlock("creating")))
    while not context.isCancelled(): sleep(5)
    return SessionResponse(sessionId: "interrupted")
  let state = cast[ptr State](userData)
  withLock state.lock:
    if state.requiresAuth and not state.authenticated:
      raise rpcError(AuthRequired, "Authentication required")
    inc state.nextId
    result.sessionId = "session-" & $state.nextId
  writeFile(request.cwd / (result.sessionId & ".history"), "created")

proc authenticate(context: RequestContext, request: AuthenticateRequest,
    userData: pointer) {.gcsafe.} =
  ## Complete the fixture's explicitly advertised authentication flow.
  let state = cast[ptr State](userData)
  withLock state.lock: state.authenticated = true

proc load(context: RequestContext, request: SessionRequest,
    userData: pointer): SessionResponse {.gcsafe.} =
  ## Replay stored history before completing session/load.
  let path = request.cwd / (request.sessionId & ".history")
  if not fileExists(path): raise rpcError(SessionNotFound, "Unknown stored session")
  context.sendUpdate(SessionUpdate(sessionId: request.sessionId,
    kind: userMessageChunk, content: textBlock("previous user message")))
  context.sendUpdate(SessionUpdate(sessionId: request.sessionId,
    kind: agentMessageChunk, content: textBlock(readFile(path))))

proc runPrompt(context: RequestContext, request: PromptRequest,
    userData: pointer): PromptResponse {.gcsafe.} =
  ## Exercise normal output, permissions, cooperative work, and application errors.
  let text = request.prompt[0].text
  if text == "error": raise newException(ValueError, "handler failure")
  if text.startsWith("permission"):
    let outcome = context.requestPermission(PermissionRequest(sessionId: request.sessionId,
      toolCall: ToolCall(toolCallId: "call-1", title: "Write a file", kind: "edit"),
      options: @[
        PermissionOption(optionId: "yes", name: "Allow", kind: "allow_once"),
        PermissionOption(optionId: "no", name: "Reject", kind: "reject_once")]))
    context.sendUpdate(SessionUpdate(sessionId: request.sessionId,
      kind: agentMessageChunk, content: textBlock(outcome.outcome & ":" & outcome.optionId)))
    if context.isCancelled(): return PromptResponse(stopReason: cancelled)
  elif text == "slow":
    context.sendUpdate(SessionUpdate(sessionId: request.sessionId,
      kind: agentMessageChunk, content: textBlock("started")))
    while not context.isCancelled(): sleep(5)
    return PromptResponse(stopReason: cancelled)
  else:
    context.sendUpdate(SessionUpdate(sessionId: request.sessionId,
      kind: agentMessageChunk, content: textBlock(text)))
    context.sendUpdate(SessionUpdate(sessionId: request.sessionId, kind: planUpdate,
      entries: @[PlanEntry(content: "Echo", priority: "normal", status: "completed")]))
  PromptResponse(stopReason: endTurn)

proc main() =
  ## Run the deterministic subprocess peer.
  let state = cast[ptr State](allocShared0(sizeof(State)))
  initLock(state.lock)
  state.requiresAuth = paramCount() > 0 and paramStr(1) == "auth"
  defer:
    deinitLock(state.lock)
    deallocShared(state)
  let methods = if state.requiresAuth: @[%*{"id": "fixture-key", "name": "Fixture login"}]
    else: newSeq[JsonNode]()
  let agent = newAcpAgent("fixture", "1", AgentHandlers(onNewSession: createSession,
    onLoadSession: load, onPrompt: runPrompt, onAuthenticate: authenticate, userData: state), methods)
  defer: agent.close()
  agent.runStdioAgent()

main()
