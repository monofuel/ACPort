import
  std/[locks, os, strtabs],
  acport,
  acport/connection

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
    sessions: ActiveSession

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
  withLock state.lock: upstream = state.upstream
  if upstream != nil: upstream.notify("session/update", update.toJsonNode())

proc relayPermission(context: RequestContext, request: PermissionRequest,
    userData: pointer): PermissionOutcome {.gcsafe.} =
  ## Bridge the real Codex permission request to the outer client.
  let state = cast[ptr RelayState](userData)
  state.activeContext(request.sessionId).requestPermission(request)

proc createSession(context: RequestContext, request: SessionRequest,
    userData: pointer): SessionResponse {.gcsafe.} =
  ## Create a real Codex session and preserve its identifier upstream.
  let state = cast[ptr RelayState](userData)
  withLock state.lock: state.upstream = context.connection
  state.backend.newSession(request.cwd, request.mcpServers, meta = request.meta).state

proc loadSession(context: RequestContext, request: SessionRequest,
    userData: pointer): SessionResponse {.gcsafe.} =
  ## Load Codex's persisted history and stream replay through both connections.
  let state = cast[ptr RelayState](userData)
  withLock state.lock: state.upstream = context.connection
  state.backend.loadSession(request.sessionId, request.cwd, request.mcpServers, meta = request.meta).state

proc runPrompt(context: RequestContext, request: PromptRequest,
    userData: pointer): PromptResponse {.gcsafe.} =
  ## Run a real Codex turn behind ACPort's agent and client APIs.
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

proc cancelSession(sessionId: string, userData: pointer) {.gcsafe.} =
  ## Forward cancellation without blocking the outer I/O reader.
  let state = cast[ptr RelayState](userData)
  AcpSession(client: state.backend, id: sessionId).cancel()

proc main() =
  ## Run the live relay; Codex remains an external executable, not a library dependency.
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
  state.backend.connect(getEnv("ACPORT_CODEX_ACP"),
    environment = newStringTable("NO_BROWSER", "1", modeCaseSensitive))
  discard state.backend.initialize(60_000)
  let agent = newAcpAgent("acport-codex-relay", AcportVersion,
    AgentHandlers(onNewSession: createSession, onLoadSession: loadSession,
      onPrompt: runPrompt, onCancel: cancelSession, userData: state))
  defer: agent.close()
  agent.runStdioAgent()

main()
