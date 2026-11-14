import
  std/[json, locks, options, os, posix],
  acport,
  acport/connection

type State = object
  lock: Lock
  nextId: int
  sessions, lastRequest: SharedText
  loggedOut: bool

proc setup(context: RequestContext, request: SessionRequest, data: pointer): SessionResponse {.gcsafe.} =
  ## Store test sessions and their complete setup requests in shared serialized state.
  let state = cast[ptr State](data)
  withLock state.lock:
    if state.loggedOut: raise rpcError(AuthRequired, "Fixture requires authentication")
    inc state.nextId
    result.sessionId = if request.sessionId.len > 0: request.sessionId else: "coverage-" & $state.nextId
    let sessions = parseJson(localText(state.sessions))
    sessions[result.sessionId] = %*{"sessionId": result.sessionId, "cwd": request.cwd,
      "additionalDirectories": request.additionalDirectories}
    freeText(state.sessions)
    state.sessions = sharedText($sessions)
    freeText(state.lastRequest)
    state.lastRequest = sharedText($request.toJsonNode(request.sessionId.len > 0))
  result.meta = request.meta

proc list(context: RequestContext, request: ListSessionsRequest, data: pointer): ListSessionsResponse {.gcsafe.} =
  ## Report the fixture's stored session descriptors without activating them.
  let state = cast[ptr State](data)
  withLock state.lock:
    for id, node in parseJson(localText(state.sessions)): result.sessions.add(parseSessionInfo(node))

proc remove(context: RequestContext, request: DeleteSessionRequest, data: pointer): DeleteSessionResponse {.gcsafe.} =
  ## Delete fixture history while deliberately leaving active runtime policy unchanged.
  let state = cast[ptr State](data)
  withLock state.lock:
    let sessions = parseJson(localText(state.sessions))
    if not sessions.hasKey(request.sessionId): raise rpcError(SessionNotFound, "Already deleted")
    sessions.delete(request.sessionId)
    freeText(state.sessions)
    state.sessions = sharedText($sessions)
  result.meta = request.meta

proc logout(context: RequestContext, request: LogoutRequest, data: pointer): LogoutResponse {.gcsafe.} =
  ## Clear only fixture authentication so tests never affect provider credentials.
  let state = cast[ptr State](data)
  withLock state.lock: state.loggedOut = true
  result.meta = request.meta

proc authenticate(context: RequestContext, request: AuthenticateRequest, data: pointer) {.gcsafe.} =
  ## Restore fixture authentication through its agent-managed method.
  let state = cast[ptr State](data)
  withLock state.lock: state.loggedOut = false

proc events(context: RequestContext, id: string) =
  ## Stream an interleaved compaction timeline with append, replace, retain and clear patches.
  context.sendUpdate(noticeUpdate(id, Notice(severity: "_custom", title: "Transient")))
  context.sendUpdate(compactionSummaryChunk(id, CompactionSummaryChunk(compactionId: "first", content: textBlock("one"),
    meta: %*{"chunkOnly": true})))
  context.sendUpdate(compactionUpdate(id, CompactionUpdate(compactionId: "second", status: "in_progress")))
  context.sendUpdate(compactionSummaryChunk(id, CompactionSummaryChunk(compactionId: "first", content: textBlock("two"))))
  context.sendUpdate(compactionUpdate(id, CompactionUpdate(compactionId: "first", status: "completed",
    errorPresent: true, error: some("old error"), metaPresent: true, meta: %*{"entity": 1})))
  context.sendUpdate(compactionUpdate(id, CompactionUpdate(compactionId: "second", status: "failed",
    summaryPresent: true, summary: some(@[textBlock("replacement")]))))

proc runPrompt(context: RequestContext, request: PromptRequest, data: pointer): PromptResponse {.gcsafe.} =
  ## Stream optional events, hold pending handles, or accept advertised rich content.
  if request.prompt.len > 0 and request.prompt[0].kind == textContent:
    case request.prompt[0].text
    of "events": context.events(request.sessionId)
    of "clear":
      context.sendUpdate(compactionUpdate(request.sessionId, CompactionUpdate(compactionId: "first", status: "completed",
        summaryPresent: true, errorPresent: true, metaPresent: true)))
      context.sendUpdate(compactionUpdate(request.sessionId, CompactionUpdate(compactionId: "second", status: "cancelled",
        summaryPresent: true, summary: some(newSeq[ContentBlock]()))))
    of "hold":
      while not context.isCancelled(): sleep(5)
    else: discard
  PromptResponse(stopReason: if context.isCancelled(): cancelled else: endTurn)

proc extension(context: RequestContext, name: string, params: JsonNode, data: pointer): JsonNode {.gcsafe.} =
  ## Exercise typed reverse requests and expose fixture setup and negotiation snapshots.
  let state = cast[ptr State](data)
  case name
  of "_caps": result = context.connection.settings()
  of "_setup":
    withLock state.lock: result = parseJson(localText(state.lastRequest))
  of "_host":
    let node = params["params"]
    case params.requiredString("method")
    of "fs/read_text_file": result = context.readTextFile(parseReadTextFileRequest(node), 5000).toJsonNode()
    of "fs/write_text_file": result = context.writeTextFile(parseWriteTextFileRequest(node), 5000).toJsonNode()
    of "terminal/create": result = context.createTerminal(parseCreateTerminalRequest(node), 5000).toJsonNode()
    of "terminal/output": result = context.terminalOutput(parseTerminalRequest(node), 5000).toJsonNode()
    of "terminal/wait_for_exit": result = context.waitForTerminalExit(parseTerminalRequest(node), 5000).toJsonNode()
    of "terminal/kill": result = context.killTerminal(parseTerminalRequest(node), 5000).toJsonNode()
    of "terminal/release": result = context.releaseTerminal(parseTerminalRequest(node), 5000).toJsonNode()
    else: raise rpcError(MethodNotFound, "Unknown host method")
  else: raise rpcError(MethodNotFound, "Unknown fixture extension")

proc main() =
  ## Serve coverage tests or run a harmless interactive authentication subprocess.
  if paramCount() > 0 and paramStr(paramCount()) == "--terminal-auth":
    doAssert isatty(0) == 1 and isatty(1) == 1 and isatty(2) == 1
    doAssert getEnv("ACPORT_AUTH_OVERRIDE") == "terminal"
    doAssert getEnv("ACPORT_AUTH_BASE") == "retained"
    doAssert getCurrentDir().normalizedPath() == getEnv("ACPORT_AUTH_CWD").normalizedPath()
    quit(0)
  let failFile = getEnv("ACPORT_INIT_FAIL_FILE")
  if failFile.len > 0 and fileExists(failFile): quit(1)
  let minimal = paramCount() > 0 and paramStr(1) == "minimal"
  let state = cast[ptr State](allocShared0(sizeof(State)))
  initLock(state.lock)
  state.sessions = sharedText("{}")
  state.lastRequest = sharedText("null")
  defer:
    freeText(state.sessions)
    freeText(state.lastRequest)
    deinitLock(state.lock)
    deallocShared(state)
  var handlers = AgentHandlers(onNewSession: setup, onPrompt: runPrompt, onExtensionRequest: extension,
    onAuthenticate: authenticate, userData: state)
  if not minimal:
    handlers.onLoadSession = setup
    handlers.onResumeSession = setup
    handlers.onListSessions = list
    handlers.onDeleteSession = remove
    handlers.onLogout = logout
  let options = if minimal: AgentOptions() else:
    AgentOptions(additionalDirectories: true, systemPrompt: true,
      systemPromptOverride: paramCount() == 0 or paramStr(1) != "append-only",
      promptCapabilities: PromptCapabilities(image: true, audio: true, embeddedContext: true),
      mcpCapabilities: McpCapabilities(http: true, sse: true))
  let agent = newAcpAgent("coverage", "1", handlers, @[
    %*{"id": "agent", "name": "Fixture"},
    %*{"id": "terminal", "name": "Fixture terminal", "type": "terminal", "args": ["--terminal-auth"],
      "env": {"ACPORT_AUTH_OVERRIDE": "terminal"}, "_meta": {"auth": true}}], options = options)
  defer: agent.close()
  agent.runStdioAgent(workerThreads = 4)

main()
