import
  std/[json, locks, os],
  acport,
  acport/connection,
  ./agent_profiles

type
  ActiveSession = ptr ActiveSessionObj
  ActiveSessionObj = object
    id: SharedText
    context: RequestContext
    active: bool
    next: ActiveSession
  RelayState = object
    lock: Lock
    backend: AcpClient
    upstream: Connection
    stopping: bool
    sessions: ActiveSession

proc rememberUpstream(state: ptr RelayState, connection: Connection) =
  ## Publish the outer connection only while its owner remains active.
  withLock state.lock:
    if not state.stopping: state.upstream = connection

proc activeContext(state: ptr RelayState, sessionId: string): RequestContext =
  ## Find the request whose permission decision is being forwarded.
  withLock state.lock:
    var session = state.sessions
    while session != nil:
      if session.active and localText(session.id) == sessionId: return session.context
      session = session.next
  raise rpcError(SessionNotFound, "No active relay session")

proc relayUpdate(update: SessionUpdate, userData: pointer) {.gcsafe.} =
  ## Forward upstream updates without changing their protocol payloads.
  let state = cast[ptr RelayState](userData)
  var upstream: Connection
  withLock state.lock:
    upstream = state.upstream
    if upstream != nil: upstream.retain()
  if upstream != nil:
    try: upstream.notify("session/update", update.toJsonNode())
    except AcpTransportError: discard # The outer peer may have disconnected during delivery.
    finally: upstream.release()

proc relayPermission(context: RequestContext, request: PermissionRequest,
    userData: pointer): PermissionOutcome {.gcsafe.} =
  ## Bridge the real backend permission request to the outer client.
  let state = cast[ptr RelayState](userData)
  state.activeContext(request.sessionId).requestPermission(request)

proc createSession(context: RequestContext, request: SessionRequest,
    userData: pointer): SessionResponse {.gcsafe.} =
  ## Create a real backend session and preserve its identifier upstream.
  let state = cast[ptr RelayState](userData)
  state.rememberUpstream(context.connection)
  state.backend.newSession(request.cwd, request.mcpServers, meta = request.meta).state

proc loadSession(context: RequestContext, request: SessionRequest,
    userData: pointer): SessionResponse {.gcsafe.} =
  ## Load persisted history and stream replay through both connections.
  let state = cast[ptr RelayState](userData)
  state.rememberUpstream(context.connection)
  state.backend.loadSession(request.sessionId, request.cwd, request.mcpServers, meta = request.meta).state

proc runPrompt(context: RequestContext, request: PromptRequest,
    userData: pointer): PromptResponse {.gcsafe.} =
  ## Run a real backend turn behind ACPort's agent and client APIs.
  let
    state = cast[ptr RelayState](userData)
    entry = cast[ActiveSession](allocShared0(sizeof(ActiveSessionObj)))
  entry.id = sharedText(request.sessionId)
  entry.context = context
  entry.active = true
  withLock state.lock:
    entry.next = state.sessions
    state.sessions = entry
  defer:
    withLock state.lock: entry.active = false
  AcpSession(client: state.backend, id: request.sessionId).prompt(request.prompt, meta = request.meta)

proc resumeSession(context: RequestContext, request: SessionRequest,
    userData: pointer): SessionResponse {.gcsafe.} =
  ## Restore the backend session without replaying conversation history.
  let state = cast[ptr RelayState](userData)
  state.rememberUpstream(context.connection)
  state.backend.resumeSession(request.sessionId, request.cwd, request.mcpServers, meta = request.meta).state

proc listSessions(context: RequestContext, request: ListSessionsRequest,
    userData: pointer): ListSessionsResponse {.gcsafe.} =
  ## Forward exactly one page with its opaque cursor and metadata.
  cast[ptr RelayState](userData).backend.listSessions(request.cwd, request.cursor, meta = request.meta)

proc closeSession(context: RequestContext, request: CloseSessionRequest,
    userData: pointer) {.gcsafe.} =
  ## Release backend resources after the outer prompt has settled.
  AcpSession(client: cast[ptr RelayState](userData).backend,
    id: request.sessionId).closeSession(meta = request.meta)

proc setConfig(context: RequestContext, request: SetConfigOptionRequest,
    userData: pointer): seq[SessionConfigOption] {.gcsafe.} =
  ## Forward settings and return the backend's complete authoritative catalog.
  AcpSession(client: cast[ptr RelayState](userData).backend,
    id: request.sessionId).setConfigOption(request.configId, request.value, meta = request.meta)

proc setMode(context: RequestContext, request: SetModeRequest,
    userData: pointer) {.gcsafe.} =
  ## Support the legacy mode endpoint explicitly.
  AcpSession(client: cast[ptr RelayState](userData).backend,
    id: request.sessionId).setMode(request.modeId, meta = request.meta)

proc cancelSession(sessionId: string, userData: pointer) {.gcsafe.} =
  ## Forward cancellation without blocking the outer I/O reader.
  let state = cast[ptr RelayState](userData)
  AcpSession(client: state.backend, id: sessionId).cancel()

proc main() =
  ## Run the selected real agent behind ACPort's client and agent APIs.
  let state = cast[ptr RelayState](allocShared0(sizeof(RelayState)))
  initLock(state.lock)
  defer:
    var session = state.sessions
    while session != nil:
      let next = session.next
      freeText(session.id)
      deallocShared(session)
      session = next
    deinitLock(state.lock)
    deallocShared(state)
  state.backend = newAcpClient("acport-relay", AcportVersion,
    ClientHandlers(onUpdate: relayUpdate, onPermission: relayPermission, userData: state))
  defer: state.backend.close()
  let
    profile = parseTestAgent(getEnv("ACPORT_TEST_AGENT", "codex"))
    command = profile.agentCommand()
  state.backend.connect(command.command, command.args, environment = command.environment)
  let info = state.backend.initialize(60_000)
  profile.authenticateAgent(state.backend, info)
  let capabilities = info.agentCapabilities.field("sessionCapabilities")
  var handlers = AgentHandlers(onNewSession: createSession, onPrompt: runPrompt,
    onCancel: cancelSession, onSetConfigOption: setConfig, onSetMode: setMode, userData: state)
  if info.agentCapabilities.field("loadSession").getBool(): handlers.onLoadSession = loadSession
  if capabilities.field("resume").kind == JObject: handlers.onResumeSession = resumeSession
  if capabilities.field("list").kind == JObject: handlers.onListSessions = listSessions
  if capabilities.field("close").kind == JObject: handlers.onCloseSession = closeSession
  let agent = newAcpAgent("acport-" & $profile & "-relay", AcportVersion, handlers)
  defer:
    withLock state.lock:
      state.stopping = true
      state.upstream = nil
    agent.close()
  agent.runStdioAgent()

main()
