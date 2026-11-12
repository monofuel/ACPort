import
  std/[locks, options, os],
  acport,
  acport/connection

type
  StoredSession = ptr StoredSessionObj
  StoredSessionObj = object
    id, cwd: SharedText
    model, mode, level: int
    enabled, closed: bool
    running, closes: int
    next: StoredSession
  State = object
    lock: Lock
    nextId: int
    style: int
    sessions: StoredSession

proc lookup(state: ptr State, id: string): StoredSession =
  ## Find application state while holding its lock.
  result = state.sessions
  while result != nil:
    if localText(result.id) == id: return
    result = result.next
  raise rpcError(SessionNotFound, "Unknown stored session")

proc catalog(session: StoredSession): seq[SessionConfigOption] =
  ## Construct settings with grouped choices and model-dependent reasoning values.
  result = @[
    SessionConfigOption(id: "model", name: "Model", category: some("model"),
      currentValue: configValue(if session.model == 0: "fast" else: "large"),
      groups: @[ConfigGroup(group: "local", name: "Models", options: @[
        ConfigChoice(value: "fast", name: "Fast"), ConfigChoice(value: "large", name: "Large")])]),
    SessionConfigOption(id: "reasoning", name: "Reasoning", category: some("thought_level"),
      currentValue: configValue(if session.model == 0: "low" else: "high"), options:
      (if session.model == 0: @[ConfigChoice(value: "low", name: "Low")]
       else: @[ConfigChoice(value: "high", name: "High")])),
    SessionConfigOption(id: "enabled", name: "Enabled", kind: booleanConfigOption,
      currentValue: configValue(session.enabled))]

proc modes(session: StoredSession): SessionModeState =
  ## Construct legacy mode information independently of config identifiers.
  SessionModeState(currentModeId: if session.mode == 0: "ask" else: "code",
    availableModes: @[SessionMode(id: "ask", name: "Ask"), SessionMode(id: "code", name: "Code")])

proc setup(state: ptr State, session: StoredSession): SessionResponse =
  ## Return the fixture's chosen config-only, legacy-only, or combined surface.
  result.sessionId = localText(session.id)
  if state.style notin [1, 3]: result.configOptions = session.catalog().toJsonNode()
  if state.style notin [2, 3]: result.modes = session.modes().toJsonNode()

proc create(context: RequestContext, request: SessionRequest,
    userData: pointer): SessionResponse {.gcsafe.} =
  ## Create a stored session with application-owned settings.
  let state = cast[ptr State](userData)
  withLock state.lock:
    inc state.nextId
    let session = cast[StoredSession](allocShared0(sizeof(StoredSessionObj)))
    session.id = sharedText("session-" & $state.nextId)
    session.cwd = sharedText(request.cwd)
    session.next = state.sessions
    state.sessions = session
    result = state.setup(session)

proc resume(context: RequestContext, request: SessionRequest,
    userData: pointer): SessionResponse {.gcsafe.} =
  ## Restore state without replaying any conversation content.
  let state = cast[ptr State](userData)
  withLock state.lock:
    let session = state.lookup(request.sessionId)
    if localText(session.cwd) != request.cwd: raise rpcError(InvalidParams, "cwd mismatch")
    session.closed = false
    result = state.setup(session)

proc load(context: RequestContext, request: SessionRequest,
    userData: pointer): SessionResponse {.gcsafe.} =
  ## Add history replay to the separately implemented resume behavior.
  result = resume(context, request, userData)
  context.sendUpdate(SessionUpdate(sessionId: request.sessionId,
    kind: agentMessageChunk, content: textBlock("history")))

proc list(context: RequestContext, request: ListSessionsRequest,
    userData: pointer): ListSessionsResponse {.gcsafe.} =
  ## Return single-item pages using deliberately opaque cursor tokens.
  let state = cast[ptr State](userData)
  withLock state.lock:
    var session = state.sessions
    if request.cursor.isSome:
      if request.cursor.get() != "next-page": raise rpcError(InvalidParams, "Invalid cursor")
      if session != nil: session = session.next
    while session != nil:
      if request.cwd.isNone or request.cwd.get() == localText(session.cwd):
        result.sessions.add(SessionInfo(sessionId: localText(session.id),
          cwd: localText(session.cwd), title: some("Stored title"), updatedAt: some("2026-11-12T00:00:00Z")))
        if session.next != nil: result.nextCursor = some("next-page")
        break
      session = session.next

proc closeSession(context: RequestContext, request: CloseSessionRequest,
    userData: pointer) {.gcsafe.} =
  ## Assert cleanup cannot race a running application prompt handler.
  let state = cast[ptr State](userData)
  withLock state.lock:
    let session = state.lookup(request.sessionId)
    doAssert session.running == 0
    session.closed = true
    inc session.closes

proc setConfig(context: RequestContext, request: SetConfigOptionRequest,
    userData: pointer): seq[SessionConfigOption] {.gcsafe.} =
  ## Change fixture state and return the full dependent catalog.
  let state = cast[ptr State](userData)
  if state.style == 5: sleep(150) # Deliberately complete after a caller's deadline.
  withLock state.lock:
    let session = state.lookup(request.sessionId)
    case request.configId
    of "model": session.model = if request.value.stringValue == "fast": 0 else: 1
    of "enabled": session.enabled = request.value.boolValue
    of "reasoning": discard
    else: raise rpcError(InvalidParams, "Unknown option")
    result = session.catalog()

proc setMode(context: RequestContext, request: SetModeRequest,
    userData: pointer) {.gcsafe.} =
  ## Support normal acknowledgements and a deliberate notification/ack race.
  let state = cast[ptr State](userData)
  var mode: string
  withLock state.lock:
    let session = state.lookup(request.sessionId)
    session.mode = if request.modeId == "ask" or state.style == 4: 0 else: 1
    mode = if session.mode == 0: "ask" else: "code"
  if state.style == 4: context.sendUpdate(currentModeUpdate(request.sessionId, mode))

proc runPrompt(context: RequestContext, request: PromptRequest,
    userData: pointer): PromptResponse {.gcsafe.} =
  ## Exercise cancellation and unsolicited configuration/metadata updates.
  let
    state = cast[ptr State](userData)
    text = request.prompt[0].text
  var session: StoredSession
  withLock state.lock:
    session = state.lookup(request.sessionId)
    doAssert not session.closed
    inc session.running
  defer:
    withLock state.lock: dec session.running
  if text == "slow":
    context.sendUpdate(SessionUpdate(sessionId: request.sessionId,
      kind: agentMessageChunk, content: textBlock("started")))
    while not context.isCancelled(): sleep(5)
    return PromptResponse(stopReason: cancelled)
  if text == "permission":
    discard context.requestPermission(PermissionRequest(sessionId: request.sessionId,
      toolCall: ToolCall(toolCallId: "permission", title: "Wait for permission"),
      options: @[PermissionOption(optionId: "yes", name: "Allow", kind: "allow_once")]))
    return PromptResponse(stopReason: if context.isCancelled(): cancelled else: endTurn)
  if text == "change":
    var options: seq[SessionConfigOption]
    withLock state.lock:
      session.model = 1
      options = session.catalog()
    context.sendUpdate(configOptionUpdate(request.sessionId, options))
  if text == "metadata":
    context.sendUpdate(sessionInfoUpdate(request.sessionId,
      SessionInfoUpdate(titlePresent: true, title: none(string),
        updatedAtPresent: true, updatedAt: some("2026-11-13T00:00:00Z"))))
  var summary: string
  withLock state.lock: summary = "closed=" & $session.closes
  context.sendUpdate(SessionUpdate(sessionId: request.sessionId,
    kind: agentMessageChunk, content: textBlock(summary)))
  PromptResponse(stopReason: endTurn)

proc main() =
  ## Serve deterministic lifecycle tests with a deliberately saturatable prompt pool.
  let state = cast[ptr State](allocShared0(sizeof(State)))
  initLock(state.lock)
  if paramCount() > 0:
    state.style = case paramStr(1)
      of "legacy": 1
      of "config": 2
      of "minimal": 3
      of "legacy-race": 4
      of "delayed-config": 5
      else: 0
  defer:
    var session = state.sessions
    while session != nil:
      let next = session.next
      freeText(session.id)
      freeText(session.cwd)
      deallocShared(session)
      session = next
    deinitLock(state.lock)
    deallocShared(state)
  var handlers = AgentHandlers(onNewSession: create, onLoadSession: load,
    onResumeSession: resume, onListSessions: list, onCloseSession: closeSession,
    onSetConfigOption: setConfig, onSetMode: setMode, onPrompt: runPrompt, userData: state)
  if state.style == 1: handlers.onSetConfigOption = nil
  if state.style == 2: handlers.onSetMode = nil
  if state.style == 3:
    handlers.onResumeSession = nil
    handlers.onListSessions = nil
    handlers.onCloseSession = nil
    handlers.onSetConfigOption = nil
    handlers.onSetMode = nil
  let agent = newAcpAgent("session-fixture", "1", handlers)
  defer: agent.close()
  agent.runStdioAgent(workerThreads = 1)

main()
