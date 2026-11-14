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

proc rememberContext(state: ptr RelayState, context: RequestContext, sessionId: string): ActiveSession =
  ## Keep an outer request alive while backend callbacks may request its host services.
  result = cast[ActiveSession](allocShared0(sizeof(ActiveSessionObj)))
  result.id = sharedText(sessionId)
  result.context = context
  result.active = true
  withLock state.lock:
    result.next = state.sessions
    state.sessions = result

proc forgetContext(state: ptr RelayState, entry: ActiveSession) =
  ## Stop exposing a context before the outer request returns.
  withLock state.lock: entry.active = false

proc relayRead(context: RequestContext, request: ReadTextFileRequest,
    userData: pointer): ReadTextFileResponse {.gcsafe.} =
  ## Forward reads only through an active outer request that negotiated read access.
  cast[ptr RelayState](userData).activeContext(request.sessionId).readTextFile(request)

proc relayWrite(context: RequestContext, request: WriteTextFileRequest,
    userData: pointer): WriteTextFileResponse {.gcsafe.} =
  ## Forward writes without introducing a filesystem policy in the relay.
  cast[ptr RelayState](userData).activeContext(request.sessionId).writeTextFile(request)

proc relayCreateTerminal(context: RequestContext, request: CreateTerminalRequest,
    userData: pointer): CreateTerminalResponse {.gcsafe.} =
  ## Forward a structured terminal invocation to the configured outer host.
  cast[ptr RelayState](userData).activeContext(request.sessionId).createTerminal(request)

proc relayOutput(context: RequestContext, request: TerminalRequest,
    userData: pointer): TerminalOutputResponse {.gcsafe.} =
  ## Forward nonconsuming output without storing terminal state in the relay.
  cast[ptr RelayState](userData).activeContext(request.sessionId).terminalOutput(request)

proc relayWait(context: RequestContext, request: TerminalRequest,
    userData: pointer): TerminalExitStatus {.gcsafe.} =
  ## Forward an exit wait using the matching outer cancellation context.
  cast[ptr RelayState](userData).activeContext(request.sessionId).waitForTerminalExit(request)

proc relayKill(context: RequestContext, request: TerminalRequest,
    userData: pointer): EmptyMessage {.gcsafe.} =
  ## Stop a host terminal while preserving its retained output.
  cast[ptr RelayState](userData).activeContext(request.sessionId).killTerminal(request)

proc relayRelease(context: RequestContext, request: TerminalRequest,
    userData: pointer): EmptyMessage {.gcsafe.} =
  ## Release terminal resources in the outer host.
  cast[ptr RelayState](userData).activeContext(request.sessionId).releaseTerminal(request)

proc forwardNotification(state: ptr RelayState, methodName: string, params: JsonNode) {.gcsafe.} =
  ## Retain the outer connection across asynchronous backend notification delivery.
  var upstream: Connection
  withLock state.lock:
    upstream = state.upstream
    if upstream != nil: upstream.retain()
  if upstream != nil:
    try: upstream.notify(methodName, params)
    except AcpTransportError: discard # The outer peer may have disconnected during delivery.
    except AcpRpcError:
      if methodName != "elicitation/complete": raise # A frontend cancellation can remove a URL flow first.
    finally: upstream.release()

proc relayUpdate(update: SessionUpdate, userData: pointer) {.gcsafe.} =
  ## Forward upstream events without changing commands, usage, or unknown payloads.
  cast[ptr RelayState](userData).forwardNotification("session/update", update.toJsonNode())

proc relayElicitation(context: RequestContext, request: ElicitationRequest,
    userData: pointer): ElicitationResponse {.gcsafe.} =
  ## Forward session-scoped interactions through their active outer prompt context.
  if request.scope != sessionElicitationScope: raise rpcError(InvalidParams, "Live relay requires session scope")
  cast[ptr RelayState](userData).activeContext(request.sessionId).requestElicitation(request)

proc relayComplete(completion: ElicitationComplete, userData: pointer) {.gcsafe.} =
  ## Forward a correlated completion while keeping browser/UI policy in the client.
  cast[ptr RelayState](userData).forwardNotification("elicitation/complete", completion.toJsonNode())

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
  if getEnv("ACPORT_TEST_HOST_IO") == "1":
    let caps = context.connection.settings().field("clientCapabilities")
    if not caps.field("terminal").getBool() or not caps.field("fs").field("readTextFile").getBool() or
        not caps.field("fs").field("writeTextFile").getBool():
      raise rpcError(InvalidParams, "Host-I/O relay profile requires matching outer callbacks")
  state.backend.newSession(request.cwd, request.mcpServers, meta = request.meta,
    additionalDirectories = request.additionalDirectories, systemPrompt = request.systemPrompt).state

proc loadSession(context: RequestContext, request: SessionRequest,
    userData: pointer): SessionResponse {.gcsafe.} =
  ## Load persisted history and stream replay through both connections.
  let state = cast[ptr RelayState](userData)
  state.rememberUpstream(context.connection)
  state.backend.loadSession(request.sessionId, request.cwd, request.mcpServers, meta = request.meta,
    additionalDirectories = request.additionalDirectories, systemPrompt = request.systemPrompt).state

proc runPrompt(context: RequestContext, request: PromptRequest,
    userData: pointer): PromptResponse {.gcsafe.} =
  ## Run a real backend turn behind ACPort's agent and client APIs.
  let state = cast[ptr RelayState](userData)
  let entry = state.rememberContext(context, request.sessionId)
  defer: state.forgetContext(entry)
  AcpSession(client: state.backend, id: request.sessionId).prompt(request.prompt, meta = request.meta)

proc resumeSession(context: RequestContext, request: SessionRequest,
    userData: pointer): SessionResponse {.gcsafe.} =
  ## Restore the backend session without replaying conversation history.
  let state = cast[ptr RelayState](userData)
  state.rememberUpstream(context.connection)
  state.backend.resumeSession(request.sessionId, request.cwd, request.mcpServers, meta = request.meta,
    additionalDirectories = request.additionalDirectories, systemPrompt = request.systemPrompt).state

proc extension(context: RequestContext, name: string, params: JsonNode,
    userData: pointer): JsonNode {.gcsafe.} =
  ## Forward custom requests while retaining the matching outer host context.
  let state = cast[ptr RelayState](userData)
  state.rememberUpstream(context.connection)
  let entry = state.rememberContext(context, params.field("sessionId").getStr())
  defer: state.forgetContext(entry)
  state.backend.requestExtension(name, params)

proc deleteSession(context: RequestContext, request: DeleteSessionRequest,
    userData: pointer): DeleteSessionResponse {.gcsafe.} =
  ## Forward history deletion only when the backend advertises it.
  cast[ptr RelayState](userData).backend.deleteSession(request.sessionId, meta = request.meta)

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
  var clientHandlers = ClientHandlers(onUpdate: relayUpdate, onPermission: relayPermission,
      onElicitationForm: if getEnv("ACPORT_TEST_AGENT") == "claude": relayElicitation else: nil,
      onElicitationUrl: if getEnv("ACPORT_TEST_AGENT") == "claude": relayElicitation else: nil,
      onElicitationComplete: relayComplete, userData: state)
  if getEnv("ACPORT_TEST_HOST_IO") == "1":
    clientHandlers.onReadTextFile = relayRead
    clientHandlers.onWriteTextFile = relayWrite
    clientHandlers.onCreateTerminal = relayCreateTerminal
    clientHandlers.onTerminalOutput = relayOutput
    clientHandlers.onWaitForTerminalExit = relayWait
    clientHandlers.onKillTerminal = relayKill
    clientHandlers.onReleaseTerminal = relayRelease
  state.backend = newAcpClient("acport-relay", AcportVersion, clientHandlers)
  defer: state.backend.close()
  let
    profile = parseTestAgent(getEnv("ACPORT_TEST_AGENT", "codex"))
    command = profile.agentCommand()
  let fixture = getEnv("ACPORT_TEST_FIXTURE")
  state.backend.connect(if fixture.len > 0: fixture else: command.command,
    if fixture.len > 0: @[] else: command.args, environment = command.environment)
  let info = state.backend.initialize(60_000)
  if fixture.len == 0: profile.authenticateAgent(state.backend, info)
  let capabilities = info.agentCapabilities.field("sessionCapabilities")
  var handlers = AgentHandlers(onNewSession: createSession, onPrompt: runPrompt,
    onCancel: cancelSession, onSetConfigOption: setConfig, onSetMode: setMode,
    onExtensionRequest: extension, userData: state)
  if info.agentCapabilities.field("loadSession").getBool(): handlers.onLoadSession = loadSession
  if capabilities.field("resume").kind == JObject: handlers.onResumeSession = resumeSession
  if capabilities.field("list").kind == JObject: handlers.onListSessions = listSessions
  if capabilities.field("close").kind == JObject: handlers.onCloseSession = closeSession
  if capabilities.field("delete").kind == JObject: handlers.onDeleteSession = deleteSession
  let options = AgentOptions(
    promptCapabilities: PromptCapabilities(image: info.agentCapabilities.field("promptCapabilities").field("image").getBool(),
      audio: info.agentCapabilities.field("promptCapabilities").field("audio").getBool(),
      embeddedContext: info.agentCapabilities.field("promptCapabilities").field("embeddedContext").getBool()),
    mcpCapabilities: McpCapabilities(http: info.agentCapabilities.field("mcpCapabilities").field("http").getBool(),
      sse: info.agentCapabilities.field("mcpCapabilities").field("sse").getBool()),
    additionalDirectories: capabilities.field("additionalDirectories").kind == JObject,
    systemPrompt: capabilities.field("systemPrompt").kind == JObject,
    systemPromptOverride: capabilities.field("systemPrompt").field("mode").field("override").kind == JObject)
  let agent = newAcpAgent("acport-" & $profile & "-relay", AcportVersion, handlers, options = options)
  defer:
    withLock state.lock:
      state.stopping = true
      state.upstream = nil
    agent.close()
  agent.runStdioAgent()

main()
