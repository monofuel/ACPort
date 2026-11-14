import
  std/[json, options, os, strtabs],
  ./[auth_protocol, connection, elicitation_protocol, events_protocol, host_protocol, processes, protocol, session_protocol]

export RequestContext, LogHandler, getRequestId, isCancelled

type
  ClientOptions* = object
    notices*, compaction*: bool
  McpCapabilities* = object
    http*, sse*: bool
  AgentOptions* = object
    promptCapabilities*: PromptCapabilities
    mcpCapabilities*: McpCapabilities
    additionalDirectories*, systemPrompt*, systemPromptOverride*: bool
  ReadTextFileHandler* = proc(context: RequestContext, request: ReadTextFileRequest,
    userData: pointer): ReadTextFileResponse {.nimcall, gcsafe.}
  WriteTextFileHandler* = proc(context: RequestContext, request: WriteTextFileRequest,
    userData: pointer): WriteTextFileResponse {.nimcall, gcsafe.}
  CreateTerminalHandler* = proc(context: RequestContext, request: CreateTerminalRequest,
    userData: pointer): CreateTerminalResponse {.nimcall, gcsafe.}
  TerminalOutputHandler* = proc(context: RequestContext, request: TerminalRequest,
    userData: pointer): TerminalOutputResponse {.nimcall, gcsafe.}
  WaitForTerminalExitHandler* = proc(context: RequestContext, request: TerminalRequest,
    userData: pointer): TerminalExitStatus {.nimcall, gcsafe.}
  TerminalControlHandler* = proc(context: RequestContext, request: TerminalRequest,
    userData: pointer): EmptyMessage {.nimcall, gcsafe.}
  TerminalAuthHandler* = proc(invocation: TerminalAuthInvocation,
    userData: pointer): TerminalExitStatus {.nimcall, gcsafe.}
  UpdateHandler* = proc(update: SessionUpdate, userData: pointer) {.nimcall, gcsafe.}
  PermissionHandler* = proc(context: RequestContext, request: PermissionRequest,
    userData: pointer): PermissionOutcome {.nimcall, gcsafe.}
  ExtensionRequestHandler* = proc(context: RequestContext, methodName: string,
    params: JsonNode, userData: pointer): JsonNode {.nimcall, gcsafe.}
  ExtensionNotificationHandler* = proc(methodName: string, params: JsonNode,
    userData: pointer) {.nimcall, gcsafe.}
  ElicitationHandler* = proc(context: RequestContext, request: ElicitationRequest,
    userData: pointer): ElicitationResponse {.nimcall, gcsafe.}
  ElicitationCompleteHandler* = proc(completion: ElicitationComplete,
    userData: pointer) {.nimcall, gcsafe.}
  ClientHandlers* = object
    onUpdate*: UpdateHandler
    onPermission*: PermissionHandler
    onLog*: LogHandler
    onElicitationForm*, onElicitationUrl*: ElicitationHandler
    onElicitationComplete*: ElicitationCompleteHandler
    onExtensionRequest*: ExtensionRequestHandler
    onExtensionNotification*: ExtensionNotificationHandler
    onReadTextFile*: ReadTextFileHandler
    onWriteTextFile*: WriteTextFileHandler
    onCreateTerminal*: CreateTerminalHandler
    onTerminalOutput*: TerminalOutputHandler
    onWaitForTerminalExit*: WaitForTerminalExitHandler
    onKillTerminal*, onReleaseTerminal*: TerminalControlHandler
    onTerminalAuth*: TerminalAuthHandler
    userData*: pointer

  NewSessionHandler* = proc(context: RequestContext, request: SessionRequest,
    userData: pointer): SessionResponse {.nimcall, gcsafe.}
  PromptHandler* = proc(context: RequestContext, request: PromptRequest,
    userData: pointer): PromptResponse {.nimcall, gcsafe.}
  AuthenticateHandler* = proc(context: RequestContext, request: AuthenticateRequest,
    userData: pointer) {.nimcall, gcsafe.}
  CancelHandler* = proc(sessionId: string, userData: pointer) {.nimcall, gcsafe.}
  SetConfigOptionHandler* = proc(context: RequestContext, request: SetConfigOptionRequest,
    userData: pointer): seq[SessionConfigOption] {.nimcall, gcsafe.}
  SetModeHandler* = proc(context: RequestContext, request: SetModeRequest,
    userData: pointer) {.nimcall, gcsafe.}
  ListSessionsHandler* = proc(context: RequestContext, request: ListSessionsRequest,
    userData: pointer): ListSessionsResponse {.nimcall, gcsafe.}
  CloseSessionHandler* = proc(context: RequestContext, request: CloseSessionRequest,
    userData: pointer) {.nimcall, gcsafe.}
  DeleteSessionHandler* = proc(context: RequestContext, request: DeleteSessionRequest,
    userData: pointer): DeleteSessionResponse {.nimcall, gcsafe.}
  LogoutHandler* = proc(context: RequestContext, request: LogoutRequest,
    userData: pointer): LogoutResponse {.nimcall, gcsafe.}
  AgentHandlers* = object
    onNewSession*, onLoadSession*: NewSessionHandler
    onPrompt*: PromptHandler
    onAuthenticate*: AuthenticateHandler
    onCancel*: CancelHandler
    onResumeSession*: NewSessionHandler
    onListSessions*: ListSessionsHandler
    onCloseSession*: CloseSessionHandler
    onDeleteSession*: DeleteSessionHandler
    onLogout*: LogoutHandler
    onSetConfigOption*: SetConfigOptionHandler
    onSetMode*: SetModeHandler
    onExtensionRequest*: ExtensionRequestHandler
    onExtensionNotification*: ExtensionNotificationHandler
    userData*: pointer

  AcpClient* = ptr object
    connection: Connection
    process: ChildProcess
    info: SharedText
    launch, initialization: SharedText
    generation: uint64
    handlers: ClientHandlers
    options: ClientOptions

  AcpAgent* = ptr object
    info, authMethods: SharedText
    handlers: AgentHandlers
    extensionCapabilities, meta: SharedText
    options: AgentOptions

  AcpSession* = object
    client*: AcpClient
    id*: string
    state*: SessionResponse
    generation: uint64

  PromptHandle* = object
    pending: PendingRequest

proc `=copy`*(destination: var PromptHandle, source: PromptHandle)
  {.error: "PromptHandle is single-owner; move it and consume it once with waitForPrompt".}

proc requireConnection(client: AcpClient): Connection =
  ## Reject calls before connecting or before initialization.
  if client.connection == nil: raise newException(AcpTransportError, "Client is not connected")
  result = client.connection
  result.retain()
  if not result.isInitialized():
    result.release()
    raise newException(AcpProtocolError, "Client has not initialized")

proc requireConnection(session: AcpSession): Connection =
  ## Reject handles returned before an authentication-triggered reconnection.
  if session.generation != 0 and session.generation != session.client.generation:
    raise newException(AcpProtocolError, "Session belongs to a previous connection; load or resume it")
  session.client.requireConnection()

proc supportsBooleanConfig*(context: RequestContext): bool =
  ## Inspect whether this client negotiated boolean configuration options.
  context.connection.settings().field("clientCapabilities").field("session").field(
    "configOptions").field("boolean").kind == JObject

proc negotiatedOptions(context: RequestContext, options: JsonNode): JsonNode =
  ## Omit boolean controls for peers that did not negotiate their wire contract.
  discard parseConfigOptions(options)
  result = newJArray()
  for option in options:
    if option.field("type").getStr() != "boolean" or context.supportsBooleanConfig():
      result.add(option)

proc getConfigOptions*(session: AcpSession): seq[SessionConfigOption] =
  ## Return an owned snapshot of the latest peer-reported configuration catalog.
  let connection = session.requireConnection()
  defer: connection.release()
  let options = connection.sessionSnapshot(session.id).field("configOptions")
  if options.kind != JNull: result = parseConfigOptions(options)

proc getModes*(session: AcpSession): Option[SessionModeState] =
  ## Return an owned snapshot of the latest legacy mode state, when available.
  let connection = session.requireConnection()
  defer: connection.release()
  let modes = connection.sessionSnapshot(session.id).field("modes")
  if modes.kind != JNull: result = some(parseModes(modes))

proc getSessionInfo*(session: AcpSession): Option[SessionInfo] =
  ## Return current session metadata without activating stored sessions.
  let connection = session.requireConnection()
  defer: connection.release()
  let info = connection.sessionSnapshot(session.id).field("info")
  if info.field("cwd").kind == JString: result = some(parseSessionInfo(info))

proc getAvailableCommands*(session: AcpSession): seq[AvailableCommand] =
  ## Copy the latest complete command catalog, or an empty list before reporting.
  let connection = session.requireConnection()
  defer: connection.release()
  let commands = connection.sessionSnapshot(session.id).field("availableCommands")
  if commands.kind != JNull: result = parseAvailableCommands(commands)

proc getUsage*(session: AcpSession): Option[UsageUpdate] =
  ## Copy the latest absolute usage report without inventing unreported usage.
  let connection = session.requireConnection()
  defer: connection.release()
  let usage = connection.sessionSnapshot(session.id).field("usage")
  if usage.kind != JNull: result = some(parseUsage(usage))

proc getCompactions*(session: AcpSession): seq[SessionCompaction] =
  ## Copy the ordered assembled compaction entities before or after callback delivery.
  let connection = session.requireConnection()
  defer: connection.release()
  let entities = connection.sessionSnapshot(session.id).field("compactions")
  if entities.kind == JArray:
    for entity in entities: result.add(parseSessionCompaction(entity))

proc requireExtension(methodName: string) =
  ## Keep custom calls in ACP's reserved extension namespace.
  if methodName.len < 2 or methodName[0] != '_':
    raise newException(ValueError, "Extension method names must start with '_' and include a name")

proc requestExtension*(client: AcpClient, methodName: string, params: JsonNode,
    timeoutMs = 0): JsonNode =
  ## Make a custom request without interpreting its opaque application payload.
  requireExtension(methodName)
  let connection = client.requireConnection()
  defer: connection.release()
  connection.request(methodName, params, timeoutMs)

proc notifyExtension*(client: AcpClient, methodName: string, params: JsonNode) =
  ## Send a custom notification without expecting a response.
  requireExtension(methodName)
  let connection = client.requireConnection()
  defer: connection.release()
  connection.notify(methodName, params)

proc requestExtension*(context: RequestContext, methodName: string, params: JsonNode,
    timeoutMs = 0): JsonNode =
  ## Make a nested extension request that cooperates with parent cancellation.
  requireExtension(methodName)
  context.connection.request(methodName, params, timeoutMs, context)

proc notifyExtension*(context: RequestContext, methodName: string, params: JsonNode) =
  ## Publish a custom notification during a live handler.
  requireExtension(methodName)
  context.connection.notify(methodName, params)

proc requireCapability(connection: Connection, capability: string) =
  ## Guard optional lifecycle methods before sending a request to the peer.
  if connection.settings().field("agentCapabilities").field("sessionCapabilities").field(capability).kind != JObject:
    raise newException(AcpProtocolError, "Peer does not support session/" & capability)

proc validateMode(modes: JsonNode, id: string) =
  ## Reject unadvertised legacy mode identifiers.
  if modes.kind != JNull:
    for mode in parseModes(modes).availableModes:
      if mode.id == id: return
  raise rpcError(InvalidParams, "Unknown session mode: " & id)

proc sendUpdate*(context: RequestContext, update: SessionUpdate) =
  ## Stream a structured session update from a request handler.
  let params = update.toJsonNode().copy()
  let kind = params["update"].field("sessionUpdate").getStr()
  if kind in ["notice", "compaction_update", "compaction_summary_chunk"]:
    let capability = if kind == "notice": "notices" else: "compaction"
    if context.connection.settings().field("clientCapabilities").field("session").field(capability).kind != JObject:
      raise newException(AcpProtocolError, "Client did not advertise session." & capability)
    case kind
    of "notice": discard parseNotice(params["update"])
    of "compaction_update": discard parseCompaction(params["update"])
    else: discard parseCompactionSummary(params["update"])
  if params["update"].field("sessionUpdate").getStr() == "config_option_update":
    params["update"]["configOptions"] = context.negotiatedOptions(params["update"].field("configOptions"))
  context.connection.notify("session/update", params)

proc hostRequest(context: RequestContext, methodName: string, params: JsonNode,
    capability: string, timeoutMs: int): JsonNode =
  ## Make an explicitly supported reverse request using the caller's cancellation context.
  if context.isCancelled(): raise newException(AcpCancelledError, "Host request cancelled")
  let capabilities = context.connection.settings().field("clientCapabilities")
  let supported = if capability == "terminal": capabilities.field("terminal").getBool()
    else: capabilities.field("fs").field(capability).getBool()
  if not supported: raise newException(AcpProtocolError, "Client did not advertise " & capability)
  context.connection.request(methodName, params, timeoutMs, context)

proc readTextFile*(context: RequestContext, request: ReadTextFileRequest, timeoutMs = 0): ReadTextFileResponse =
  ## Ask the host for text, allowing editor buffers and host-specific permissions.
  let params = request.toJsonNode()
  discard parseReadTextFileRequest(params)
  parseReadTextFileResponse(context.hostRequest("fs/read_text_file", params, "readTextFile", timeoutMs))

proc writeTextFile*(context: RequestContext, request: WriteTextFileRequest, timeoutMs = 0): WriteTextFileResponse =
  ## Ask the host to replace text without performing filesystem access in ACPort.
  let params = request.toJsonNode()
  discard parseWriteTextFileRequest(params)
  parseEmptyMessage(context.hostRequest("fs/write_text_file", params, "writeTextFile", timeoutMs))

proc createTerminal*(context: RequestContext, request: CreateTerminalRequest, timeoutMs = 0): CreateTerminalResponse =
  ## Ask the host to start a terminal and return its identifier before exit.
  let params = request.toJsonNode()
  discard parseCreateTerminalRequest(params)
  parseCreateTerminalResponse(context.hostRequest("terminal/create", params, "terminal", timeoutMs))

proc terminalOutput*(context: RequestContext, request: TerminalRequest, timeoutMs = 0): TerminalOutputResponse =
  ## Read a nonblocking host terminal snapshot without consuming retained output.
  let params = request.toJsonNode()
  discard parseTerminalRequest(params)
  parseTerminalOutputResponse(context.hostRequest("terminal/output", params, "terminal", timeoutMs))

proc waitForTerminalExit*(context: RequestContext, request: TerminalRequest, timeoutMs = 0): TerminalExitStatus =
  ## Wait cooperatively for exit; cancelling this request does not kill the terminal.
  let params = request.toJsonNode()
  discard parseTerminalRequest(params)
  parseTerminalExitStatus(context.hostRequest("terminal/wait_for_exit", params, "terminal", timeoutMs))

proc killTerminal*(context: RequestContext, request: TerminalRequest, timeoutMs = 0): KillTerminalResponse =
  ## Stop a host terminal while keeping its identity and output available.
  let params = request.toJsonNode()
  discard parseTerminalRequest(params)
  parseEmptyMessage(context.hostRequest("terminal/kill", params, "terminal", timeoutMs))

proc releaseTerminal*(context: RequestContext, request: TerminalRequest, timeoutMs = 0): ReleaseTerminalResponse =
  ## Ask the host to stop and free a terminal owned by this session.
  let params = request.toJsonNode()
  discard parseTerminalRequest(params)
  parseEmptyMessage(context.hostRequest("terminal/release", params, "terminal", timeoutMs))

proc requestPermission*(context: RequestContext, permission: PermissionRequest,
    timeoutMs = 0): PermissionOutcome =
  ## Request authorization while continuing to receive cancellation and replies.
  if context.isCancelled(): return PermissionOutcome(outcome: "cancelled")
  try:
    result = parsePermissionOutcome(context.connection.request("session/request_permission",
      permission.toJsonNode(), timeoutMs, context))
  except AcpCancelledError:
    result = PermissionOutcome(outcome: "cancelled")
  if result.outcome == "selected":
    var found = false
    for option in permission.options:
      if option.optionId == result.optionId: found = true
    if not found: raise newException(AcpProtocolError, "Peer selected an unknown permission option")

proc requestElicitation*(context: RequestContext, request: ElicitationRequest,
    timeoutMs = 0): ElicitationResponse =
  ## Ask an explicitly supported mode, preserving cancellation and opaque form data.
  if context.isCancelled(): return ElicitationResponse(action: cancelElicitation)
  var effective = request
  if effective.raw == nil and effective.scope == requestElicitationScope and effective.requestId == nil:
    effective.requestId = context.getRequestId()
  let params = effective.toJsonNode()
  let parsed = parseElicitationRequest(params)
  let mode = case parsed.mode
    of formElicitation: "form"
    of urlElicitation: "url"
    else: raise newException(AcpProtocolError, "Unsupported elicitation mode")
  if context.connection.settings().field("clientCapabilities").field("elicitation").field(mode).kind != JObject:
    raise newException(AcpProtocolError, "Client did not advertise elicitation mode: " & mode)
  try:
    result = parseElicitationResponse(context.connection.request("elicitation/create", params, timeoutMs, context))
  except AcpCancelledError:
    result = ElicitationResponse(action: cancelElicitation)

proc completeElicitation*(context: RequestContext, elicitationId: string, meta: JsonNode = nil) =
  ## Report external URL-flow completion during a live handler without opening the URL.
  if context.isCancelled(): raise newException(AcpCancelledError, "Elicitation context cancelled")
  context.connection.notify("elicitation/complete", ElicitationComplete(elicitationId: elicitationId, meta: meta).toJsonNode())

proc clientRequest(context: RequestContext, methodName: string,
    params: JsonNode): JsonNode {.gcsafe.} =
  ## Dispatch agent requests to the application's explicit permission policy.
  let client = cast[AcpClient](context.userData())
  if methodName in ["fs/read_text_file", "fs/write_text_file", "terminal/create", "terminal/output",
      "terminal/wait_for_exit", "terminal/kill", "terminal/release"]:
    if not context.connection.isInitialized(): raise rpcError(InvalidRequest, "Not initialized")
    if context.isCancelled(): raise newException(AcpCancelledError, "Host request cancelled")
    case methodName
    of "fs/read_text_file":
      if client.handlers.onReadTextFile == nil: raise rpcError(MethodNotFound, "File reading is unsupported")
      result = client.handlers.onReadTextFile(context, parseReadTextFileRequest(params), client.handlers.userData).toJsonNode()
      discard parseReadTextFileResponse(result)
    of "fs/write_text_file":
      if client.handlers.onWriteTextFile == nil: raise rpcError(MethodNotFound, "File writing is unsupported")
      result = client.handlers.onWriteTextFile(context, parseWriteTextFileRequest(params), client.handlers.userData).toJsonNode()
      discard parseEmptyMessage(result)
    of "terminal/create":
      if client.handlers.onCreateTerminal == nil: raise rpcError(MethodNotFound, "Terminals are unsupported")
      result = client.handlers.onCreateTerminal(context, parseCreateTerminalRequest(params), client.handlers.userData).toJsonNode()
      discard parseCreateTerminalResponse(result)
    of "terminal/output":
      if client.handlers.onTerminalOutput == nil: raise rpcError(MethodNotFound, "Terminals are unsupported")
      result = client.handlers.onTerminalOutput(context, parseTerminalRequest(params), client.handlers.userData).toJsonNode()
      discard parseTerminalOutputResponse(result)
    of "terminal/wait_for_exit":
      if client.handlers.onWaitForTerminalExit == nil: raise rpcError(MethodNotFound, "Terminals are unsupported")
      result = client.handlers.onWaitForTerminalExit(context, parseTerminalRequest(params), client.handlers.userData).toJsonNode()
      discard parseTerminalExitStatus(result)
    of "terminal/kill", "terminal/release":
      let handler = if methodName == "terminal/kill": client.handlers.onKillTerminal else: client.handlers.onReleaseTerminal
      if handler == nil: raise rpcError(MethodNotFound, "Terminals are unsupported")
      result = handler(context, parseTerminalRequest(params), client.handlers.userData).toJsonNode()
      discard parseEmptyMessage(result)
    else: discard
    return
  if methodName == "elicitation/create":
    let request = parseElicitationRequest(params)
    let handler = case request.mode
      of formElicitation: client.handlers.onElicitationForm
      of urlElicitation: client.handlers.onElicitationUrl
      else: nil
    if handler == nil: raise rpcError(InvalidParams, "Elicitation mode was not advertised")
    if context.isCancelled(): return ElicitationResponse(action: cancelElicitation).toJsonNode()
    let response = handler(context, request, client.handlers.userData)
    if context.isCancelled(): return ElicitationResponse(action: cancelElicitation).toJsonNode()
    result = response.toJsonNode()
    discard parseElicitationResponse(result)
    return
  if methodName != "session/request_permission":
    if methodName.len > 1 and methodName[0] == '_' and client.handlers.onExtensionRequest != nil:
      return client.handlers.onExtensionRequest(context, methodName, params, client.handlers.userData)
    raise rpcError(MethodNotFound, "Method not found: " & methodName)
  let permission = parsePermission(params)
  var outcome = PermissionOutcome(outcome: "cancelled")
  if not context.isCancelled() and client.handlers.onPermission != nil:
    outcome = client.handlers.onPermission(context, permission, client.handlers.userData)
  if context.isCancelled(): outcome = PermissionOutcome(outcome: "cancelled")
  if outcome.outcome == "selected":
    var found = false
    for option in permission.options:
      if option.optionId == outcome.optionId: found = true
    if not found: raise rpcError(InvalidParams, "Permission handler selected an unknown option")
  elif outcome.outcome != "cancelled":
    raise rpcError(InvalidParams, "Invalid permission outcome")
  outcome.toJsonNode()

proc clientNotification(context: RequestContext, methodName: string,
    params: JsonNode) {.gcsafe.} =
  ## Deliver structured session updates on the ordered callback thread.
  let client = cast[AcpClient](context.userData())
  if methodName == "session/update":
    let update = parseUpdate(params)
    if client.handlers.onUpdate != nil:
      client.handlers.onUpdate(update, client.handlers.userData)
  elif methodName.len > 1 and methodName[0] == '_' and client.handlers.onExtensionNotification != nil:
    client.handlers.onExtensionNotification(methodName, params, client.handlers.userData)
  elif methodName == "elicitation/complete" and client.handlers.onElicitationComplete != nil:
    client.handlers.onElicitationComplete(parseElicitationComplete(params), client.handlers.userData)

proc clientLog(userData: pointer, text: string) {.gcsafe.} =
  ## Forward child diagnostics without mixing stderr into protocol traffic.
  let client = cast[AcpClient](userData)
  if client.handlers.onLog != nil:
    client.handlers.onLog(client.handlers.userData, text)

proc newAcpClient*(name: string, version: string,
    handlers = ClientHandlers(), options = ClientOptions()): AcpClient =
  ## Allocate a client; connect and close it on its owning application thread.
  let terminalCount = int(handlers.onCreateTerminal != nil) + int(handlers.onTerminalOutput != nil) +
    int(handlers.onWaitForTerminalExit != nil) + int(handlers.onKillTerminal != nil) + int(handlers.onReleaseTerminal != nil)
  if terminalCount notin [0, 5]: raise newException(ValueError, "Terminal support requires all five callbacks")
  result = cast[AcpClient](allocShared0(sizeof(result[])))
  result.info = sharedText($(%*{"name": name, "version": version}))
  result.handlers = handlers
  result.options = options

proc connect*(client: AcpClient, command: string, args: seq[string] = @[],
    workingDir = "", environment: StringTableRef = nil,
    workerThreads = DefaultWorkerThreads) =
  ## Launch an agent with separate pipes and inherited environment plus overrides.
  if client.connection != nil: raise newException(AcpProtocolError, "Client is already connected")
  if workerThreads < 1: raise newException(ValueError, "At least one request worker is required")
  var launch = %*{"command": command, "args": args, "workingDir": workingDir,
    "workerThreads": workerThreads, "environment": {}}
  for key, value in envPairs(): launch["environment"][key] = %value
  if environment != nil:
    for key, value in environment: launch["environment"][key] = %value
  client.process = spawnAgent(command, args, workingDir, environment)
  try:
    client.connection = newConnection(client.process.outputFd,
      client.process.inputFd, clientRequest, clientNotification,
      client, client.process.errorFd, clientLog, workerThreads)
  except CatchableError:
    client.process.close()
    raise
  freeText(client.launch)
  client.launch = sharedText($launch)
  inc client.generation

proc initialize*(client: AcpClient, timeoutMs = 0, extensionCapabilities: JsonNode = nil,
    meta: JsonNode = nil): InitializeResponse =
  ## Negotiate ACP v1 without advertising unimplemented client capabilities.
  if client.connection == nil: raise newException(AcpTransportError, "Client is not connected")
  if client.connection.isInitialized(): raise newException(AcpProtocolError, "Already initialized")
  var params = %*{
    "protocolVersion": ProtocolVersion,
    "clientCapabilities": {"session": {"configOptions": {"boolean": {}}}},
    "clientInfo": parseJson(localText(client.info))}
  var elicitation = newJObject()
  let capabilities = params["clientCapabilities"]
  if client.handlers.onReadTextFile != nil or client.handlers.onWriteTextFile != nil:
    capabilities["fs"] = %*{"readTextFile": client.handlers.onReadTextFile != nil,
      "writeTextFile": client.handlers.onWriteTextFile != nil}
  if client.handlers.onCreateTerminal != nil: capabilities["terminal"] = %true
  if client.handlers.onTerminalAuth != nil: capabilities["auth"] = %*{"terminal": true}
  if client.options.notices: capabilities["session"]["notices"] = newJObject()
  if client.options.compaction: capabilities["session"]["compaction"] = newJObject()
  if client.handlers.onElicitationForm != nil: elicitation["form"] = newJObject()
  if client.handlers.onElicitationUrl != nil: elicitation["url"] = newJObject()
  if elicitation.len > 0: params["clientCapabilities"]["elicitation"] = elicitation
  if extensionCapabilities != nil and extensionCapabilities.kind != JNull:
    extensionCapabilities.requireObject()
    params["clientCapabilities"]["_meta"] = extensionCapabilities
  if meta != nil: params["_meta"] = meta
  let response = client.connection.request("initialize", params, timeoutMs)
  if response.field("protocolVersion").kind != JInt or
      response["protocolVersion"].getInt() != ProtocolVersion:
    raise newException(AcpProtocolError, "Peer did not negotiate ACP v1; close this connection")
  try:
    result = decodeRecord(response, InitializeResponse)
  except AcpRpcError as error:
    raise newException(AcpProtocolError, "Invalid initialize response: " & error.msg)
  result.meta = response.field("_meta")
  if result.agentInfo.isSome:
    var info = result.agentInfo.get()
    info.meta = response.field("agentInfo").field("_meta")
    info.raw = response.field("agentInfo")
    result.agentInfo = some(info)
  client.connection.setSettings(response)
  client.connection.markInitialized()
  freeText(client.initialization)
  client.initialization = sharedText($params)

proc disconnect(client: AcpClient) =
  ## Stop transport threads and reap the process while preserving the client allocation.
  if client.connection != nil:
    client.connection.close()
    client.connection = nil
  client.process.close()

proc authenticateTerminal*(client: AcpClient, methodId: string, timeoutMs = 0): InitializeResponse =
  ## Run host-owned interactive auth on the owner thread, then reconnect only after success.
  let connection = client.requireConnection()
  defer: connection.release()
  if client.handlers.onTerminalAuth == nil: raise newException(AcpProtocolError, "Terminal authentication is unsupported")
  var selected: AuthMethod
  var found = false
  let methods = connection.settings().field("authMethods")
  if methods.kind == JArray:
    for methodInfo in methods:
      if methodInfo.field("id").getStr() == methodId:
        selected = parseAuthMethod(methodInfo)
        found = selected.kind == "terminal"
        break
  if not found: raise newException(AcpProtocolError, "No advertised terminal authentication method: " & methodId)
  let
    launch = parseJson(localText(client.launch))
    initialization = parseJson(localText(client.initialization))
  var invocation = TerminalAuthInvocation(methodInfo: selected, command: launch.requiredString("command"),
    workingDir: launch.requiredString("workingDir"), environment: newStringTable(modeCaseSensitive))
  for arg in launch["args"]: invocation.args.add(arg.getStr())
  invocation.args.add(selected.args)
  for key, value in launch["environment"]: invocation.environment[key] = value.getStr()
  if selected.env.kind == JObject:
    for key, value in selected.env: invocation.environment[key] = value.getStr()
  let status = client.handlers.onTerminalAuth(invocation, client.handlers.userData)
  if status.signal.isSome or status.exitCode.isNone or status.exitCode.get() != 0:
    raise newException(AcpError, "Terminal authentication did not exit successfully")
  client.disconnect()
  try:
    var args: seq[string]
    var environment = newStringTable(modeCaseSensitive)
    for arg in launch["args"]: args.add(arg.getStr())
    for key, value in launch["environment"]: environment[key] = value.getStr()
    client.connect(launch.requiredString("command"), args, launch.requiredString("workingDir"),
      environment, launch["workerThreads"].getInt())
    result = client.initialize(timeoutMs,
      initialization["clientCapabilities"].field("_meta"), initialization.field("_meta"))
  except CatchableError:
    client.disconnect()
    raise

proc authenticate*(client: AcpClient, methodId: string, timeoutMs = 0,
    meta: JsonNode = nil) =
  ## Invoke an advertised agent-managed authentication method.
  let connection = client.requireConnection()
  defer: connection.release()
  let methods = connection.settings().field("authMethods")
  var found = false
  if methods.kind == JArray:
    for authMethod in methods:
      if authMethod.field("id").getStr() == methodId and
          authMethod.field("type").getStr("agent") == "agent": found = true
  if not found: raise newException(AcpProtocolError, "No advertised agent authentication method: " & methodId)
  var params = %*{"methodId": methodId}
  if meta != nil: params["_meta"] = meta
  discard connection.request("authenticate", params, timeoutMs)

proc logout*(client: AcpClient, timeoutMs = 0, meta: JsonNode = nil): LogoutResponse =
  ## Ask the agent to clear authentication; credential and active-session policy remain agent-owned.
  let connection = client.requireConnection()
  defer: connection.release()
  if connection.settings().field("agentCapabilities").field("auth").field("logout").kind != JObject:
    raise newException(AcpProtocolError, "Peer does not support logout")
  parseEmptyMessage(connection.request("logout", LogoutRequest(meta: meta).toJsonNode(), timeoutMs))

proc deleteSession*(client: AcpClient, sessionId: string, timeoutMs = 0,
    meta: JsonNode = nil): DeleteSessionResponse =
  ## Remove stored history independently of active sessions, treating an absent ID as success.
  let connection = client.requireConnection()
  defer: connection.release()
  connection.requireCapability("delete")
  try:
    result = parseEmptyMessage(connection.request("session/delete",
      DeleteSessionRequest(sessionId: sessionId, meta: meta).toJsonNode(), timeoutMs))
  except AcpRpcError as error:
    if error.code != SessionNotFound: raise

proc validateSessionSetup(request: SessionRequest, capabilities: JsonNode) =
  ## Reject unsupported workspace roots and system instructions before session creation or restore.
  discard parseDirectories(%request.additionalDirectories)
  if request.additionalDirectories.len > 0 and capabilities.field("additionalDirectories").kind != JObject:
    raise rpcError(InvalidParams, "Additional directories were not advertised")
  if request.systemPrompt.isSome:
    let prompt = parseSystemPrompt(request.systemPrompt.get().toJsonNode())
    let supported = capabilities.field("systemPrompt")
    if supported.kind != JObject: raise rpcError(InvalidParams, "System prompts were not advertised")
    if prompt.mode != "append" and not (prompt.mode == "override" and
        supported.field("mode").field("override").kind == JObject):
      raise rpcError(InvalidParams, "System prompt mode was not advertised: " & prompt.mode)

proc newSession*(client: AcpClient, cwd: string,
    mcpServers: seq[JsonNode] = @[], timeoutMs = 0, meta: JsonNode = nil,
    additionalDirectories: seq[string] = @[], systemPrompt: Option[SystemPrompt] = none(SystemPrompt)): AcpSession =
  ## Create an independent conversation with an absolute working directory.
  if not cwd.isAbsolute(): raise newException(ValueError, "Session cwd must be absolute")
  let connection = client.requireConnection()
  defer: connection.release()
  let request = SessionRequest(cwd: cwd, mcpServers: mcpServers, meta: meta,
    additionalDirectories: additionalDirectories, systemPrompt: systemPrompt)
  validateSessionSetup(request, connection.settings().field("agentCapabilities").field("sessionCapabilities"))
  let
    response = connection.request("session/new",
      request.toJsonNode(), timeoutMs)
    state = parseSessionResponse(response)
  connection.registerSession(state.sessionId)
  AcpSession(client: client, id: state.sessionId, state: state, generation: client.generation)

proc loadSession*(client: AcpClient, sessionId: string, cwd: string,
    mcpServers: seq[JsonNode] = @[], timeoutMs = 0, meta: JsonNode = nil,
    additionalDirectories: seq[string] = @[], systemPrompt: Option[SystemPrompt] = none(SystemPrompt)): AcpSession =
  ## Load an existing session, delivering replay updates before returning.
  if not cwd.isAbsolute(): raise newException(ValueError, "Session cwd must be absolute")
  let connection = client.requireConnection()
  defer: connection.release()
  if not connection.settings().field("agentCapabilities").field("loadSession").getBool():
    raise newException(AcpProtocolError, "Peer does not support session/load")
  let request = SessionRequest(cwd: cwd, sessionId: sessionId, mcpServers: mcpServers,
    meta: meta, additionalDirectories: additionalDirectories, systemPrompt: systemPrompt)
  validateSessionSetup(request, connection.settings().field("agentCapabilities").field("sessionCapabilities"))
  let state = parseSessionResponse(connection.request("session/load",
    request.toJsonNode(true),
    timeoutMs), sessionId)
  connection.registerSession(sessionId, allowExisting = true)
  AcpSession(client: client, id: sessionId, state: state, generation: client.generation)

proc listSessions*(client: AcpClient, cwd = none(string), cursor = none(string),
    timeoutMs = 0, meta: JsonNode = nil): ListSessionsResponse =
  ## Fetch one capability-gated page of stored sessions without activating them.
  if cwd.isSome and not cwd.get().isAbsolute():
    raise newException(ValueError, "Session cwd filter must be absolute")
  let connection = client.requireConnection()
  defer: connection.release()
  connection.requireCapability("list")
  result = parseListSessionsResponse(connection.request("session/list",
    ListSessionsRequest(cwd: cwd, cursor: cursor, meta: meta).toJsonNode(), timeoutMs))

proc resumeSession*(client: AcpClient, sessionId: string, cwd: string,
    mcpServers: seq[JsonNode] = @[], timeoutMs = 0, meta: JsonNode = nil,
    additionalDirectories: seq[string] = @[], systemPrompt: Option[SystemPrompt] = none(SystemPrompt)): AcpSession =
  ## Restore a session without replaying its conversation history.
  if not cwd.isAbsolute(): raise newException(ValueError, "Session cwd must be absolute")
  let connection = client.requireConnection()
  defer: connection.release()
  connection.requireCapability("resume")
  let request = SessionRequest(cwd: cwd, sessionId: sessionId, mcpServers: mcpServers,
    meta: meta, additionalDirectories: additionalDirectories, systemPrompt: systemPrompt)
  validateSessionSetup(request, connection.settings().field("agentCapabilities").field("sessionCapabilities"))
  let state = parseSessionResponse(connection.request("session/resume",
    request.toJsonNode(true), timeoutMs), sessionId)
  connection.registerSession(sessionId, allowExisting = true)
  AcpSession(client: client, id: sessionId, state: state, generation: client.generation)

proc closeSession*(session: AcpSession, timeoutMs = 0, meta: JsonNode = nil) =
  ## Cancel and release one active session without deleting history or closing the client.
  let connection = session.requireConnection()
  defer: connection.release()
  connection.requireCapability("close")
  if connection.sessionIsClosed(session.id): return
  connection.markSessionClosing(session.id)
  var params = %*{"sessionId": session.id}
  if meta != nil: params["_meta"] = meta
  try:
    discard connection.request("session/close", params, timeoutMs)
  except AcpRpcError as error:
    if error.code != SessionNotFound: raise

proc setConfigOption*(session: AcpSession, configId: string, value: ConfigValue,
    timeoutMs = 0, meta: JsonNode = nil): seq[SessionConfigOption] =
  ## Change an advertised option and return the complete updated configuration catalog.
  let connection = session.requireConnection()
  defer: connection.release()
  connection.requireOpenSession(session.id)
  validateConfigValue(session.getConfigOptions(), configId, value)
  result = parseConfigOptions(connection.request("session/set_config_option",
    SetConfigOptionRequest(sessionId: session.id, configId: configId,
      value: value, meta: meta).toJsonNode(), timeoutMs).field("configOptions"))

proc setConfigOption*(session: AcpSession, configId: string, value: string,
    timeoutMs = 0, meta: JsonNode = nil): seq[SessionConfigOption] =
  ## Set a select option using its advertised string value identifier.
  session.setConfigOption(configId, configValue(value), timeoutMs, meta)

proc setConfigOption*(session: AcpSession, configId: string, value: bool,
    timeoutMs = 0, meta: JsonNode = nil): seq[SessionConfigOption] =
  ## Set a negotiated boolean option.
  session.setConfigOption(configId, configValue(value), timeoutMs, meta)

proc setMode*(session: AcpSession, modeId: string, timeoutMs = 0, meta: JsonNode = nil) =
  ## Invoke the explicit legacy mode setter without guessing config-option identifiers.
  let connection = session.requireConnection()
  defer: connection.release()
  connection.requireOpenSession(session.id)
  validateMode(connection.sessionSnapshot(session.id).field("modes"), modeId)
  var params = %*{"sessionId": session.id, "modeId": modeId}
  if meta != nil: params["_meta"] = meta
  discard connection.request("session/set_mode", params, timeoutMs)

proc validateContent(prompt: seq[ContentBlock], capabilities: JsonNode) =
  ## Enforce advertised prompt content capabilities before dispatch.
  for content in prompt:
    let allowed = case content.kind
      of textContent, resourceLinkContent: true
      of imageContent: capabilities.field("image").getBool()
      of audioContent: capabilities.field("audio").getBool()
      of resourceContent: capabilities.field("embeddedContext").getBool()
      of unknownContent: false
    if not allowed: raise rpcError(InvalidParams, "Prompt content is not supported by the agent")

proc startPrompt*(session: AcpSession, prompt: seq[ContentBlock], meta: JsonNode = nil): PromptHandle =
  ## Begin a turn; consume the returned handle exactly once with waitForPrompt.
  let connection = session.requireConnection()
  defer: connection.release()
  validateContent(prompt, connection.settings().field("agentCapabilities").field("promptCapabilities"))
  connection.beginPrompt(session.id)
  try:
    result = PromptHandle(pending: connection.startRequest("session/prompt",
        PromptRequest(sessionId: session.id, prompt: prompt, meta: meta).toJsonNode()))
  except CatchableError:
    connection.endPrompt(session.id)
    raise

proc isReady*(handle: PromptHandle): bool =
  ## Poll completion or terminal failure without consuming the handle or waiting.
  if handle.pending == nil: raise newException(ValueError, "Prompt handle was already consumed")
  handle.pending.isReady()

proc waitForPrompt*(handle: var PromptHandle, timeoutMs = 0): PromptResponse =
  ## Consume a prompt completion after its earlier updates have been delivered.
  if handle.pending == nil: raise newException(ValueError, "Prompt handle was already consumed")
  let pending = handle.pending
  handle.pending = nil
  result = parsePromptResponse(waitResponse(pending, timeoutMs))

proc prompt*(session: AcpSession, content: seq[ContentBlock], timeoutMs = 0,
    meta: JsonNode = nil): PromptResponse =
  ## Run a turn synchronously while background threads deliver updates and permissions.
  var handle = session.startPrompt(content, meta)
  waitForPrompt(handle, timeoutMs)

proc prompt*(session: AcpSession, text: string, timeoutMs = 0): PromptResponse =
  ## Run a plain-text turn using the same structured prompt API.
  session.prompt(@[textBlock(text)], timeoutMs)

proc cancel*(session: AcpSession) =
  ## Request cooperative cancellation while keeping the session reusable.
  let connection = session.requireConnection()
  defer: connection.release()
  connection.cancel(session.id)

proc isPromptActive*(session: AcpSession): bool =
  ## Check whether a cancelled or timed-out turn has received its completion yet.
  let connection = session.requireConnection()
  defer: connection.release()
  connection.isPromptActive(session.id)

proc close*(client: AcpClient) =
  ## Stop connection threads, reap the owned process group, and release the client.
  client.disconnect()
  freeText(client.info)
  freeText(client.launch)
  freeText(client.initialization)
  deallocShared(client)

proc agentCapabilities(agent: AcpAgent): JsonNode =
  ## Build only capabilities backed by application handlers and explicit declarations.
  result = %*{"loadSession": agent.handlers.onLoadSession != nil,
    "promptCapabilities": (%agent.options.promptCapabilities),
    "mcpCapabilities": (%agent.options.mcpCapabilities), "sessionCapabilities": {}}
  let sessions = result["sessionCapabilities"]
  if agent.handlers.onListSessions != nil: sessions["list"] = newJObject()
  if agent.handlers.onResumeSession != nil: sessions["resume"] = newJObject()
  if agent.handlers.onCloseSession != nil: sessions["close"] = newJObject()
  if agent.handlers.onDeleteSession != nil: sessions["delete"] = newJObject()
  if agent.options.additionalDirectories: sessions["additionalDirectories"] = newJObject()
  if agent.options.systemPrompt:
    sessions["systemPrompt"] = newJObject()
    if agent.options.systemPromptOverride: sessions["systemPrompt"]["mode"] = %*{"override": {}}
  if agent.handlers.onLogout != nil: result["auth"] = %*{"logout": {}}
  let extensions = parseJson(localText(agent.extensionCapabilities))
  if extensions.kind != JNull: result["_meta"] = extensions

proc agentRequest(context: RequestContext, methodName: string,
    params: JsonNode): JsonNode {.gcsafe.} =
  ## Dispatch core agent methods with capability and session-state checks.
  let agent = cast[AcpAgent](context.userData())
  if methodName == "initialize":
    if params.field("protocolVersion").kind != JInt:
      raise rpcError(InvalidParams, "Missing protocolVersion")
    context.connection.markInitialized()
    context.connection.setSettings(params)
    var methods = newJArray()
    let terminalAuth = params.field("clientCapabilities").field("auth").field("terminal").getBool()
    for methodInfo in parseJson(localText(agent.authMethods)):
      if methodInfo.field("type").getStr("agent") != "terminal" or terminalAuth: methods.add(methodInfo)
    result = %*{"protocolVersion": ProtocolVersion,
      "agentInfo": parseJson(localText(agent.info)),
      "agentCapabilities": agent.agentCapabilities(), "authMethods": methods}
    let meta = parseJson(localText(agent.meta))
    if meta.kind != JNull: result["_meta"] = meta
    return
  if not context.connection.isInitialized(): raise rpcError(InvalidRequest, "Not initialized")
  case methodName
  of "authenticate":
    let id = params.requiredString("methodId")
    var found = false
    for authMethod in parseJson(localText(agent.authMethods)):
      if authMethod.field("id").getStr() == id and authMethod.field("type").getStr("agent") == "agent": found = true
    if agent.handlers.onAuthenticate == nil or not found:
      raise rpcError(InvalidParams, "Unsupported authentication method")
    agent.handlers.onAuthenticate(context, AuthenticateRequest(methodId: id,
      meta: params.field("_meta")), agent.handlers.userData)
    result = newJObject()
  of "logout":
    if agent.handlers.onLogout == nil: raise rpcError(MethodNotFound, "Logout is unsupported")
    result = agent.handlers.onLogout(context, parseEmptyMessage(params), agent.handlers.userData).toJsonNode()
    discard parseEmptyMessage(result)
  of "session/delete":
    if agent.handlers.onDeleteSession == nil: raise rpcError(MethodNotFound, "Session deletion is unsupported")
    try:
      result = agent.handlers.onDeleteSession(context, parseDeleteSessionRequest(params), agent.handlers.userData).toJsonNode()
    except AcpRpcError as error:
      if error.code != SessionNotFound: raise
      result = newJObject()
    discard parseEmptyMessage(result)
  of "session/new", "session/load", "session/resume":
    let
      load = methodName != "session/new"
      request = parseSessionRequest(params, load, methodName == "session/resume")
      handler = case methodName
        of "session/new": agent.handlers.onNewSession
        of "session/load": agent.handlers.onLoadSession
        else: agent.handlers.onResumeSession
    if not request.cwd.isAbsolute(): raise rpcError(InvalidParams, "Session cwd must be absolute")
    validateSessionSetup(request, agent.agentCapabilities().field("sessionCapabilities"))
    if handler == nil: raise rpcError(MethodNotFound, "Method not found: " & methodName)
    var response = handler(context, request, agent.handlers.userData)
    if response.configOptions != nil and response.configOptions.kind != JNull:
      response.configOptions = context.negotiatedOptions(response.configOptions)
    if load: response.sessionId = request.sessionId
    context.connection.registerSession(response.sessionId, allowExisting = load)
    result = response.toJsonNode(load)
  of "session/list":
    if agent.handlers.onListSessions == nil: raise rpcError(MethodNotFound, "Session listing is unsupported")
    let request = parseListSessionsRequest(params)
    if request.cwd.isSome and not request.cwd.get().isAbsolute():
      raise rpcError(InvalidParams, "Session cwd filter must be absolute")
    result = agent.handlers.onListSessions(context, request, agent.handlers.userData).toJsonNode()
  of "session/set_config_option":
    if agent.handlers.onSetConfigOption == nil: raise rpcError(MethodNotFound, "Configuration changes are unsupported")
    let request = parseSetConfigOption(params)
    context.connection.requireOpenSession(request.sessionId)
    if request.value.kind == booleanConfigValue and not context.supportsBooleanConfig():
      raise rpcError(InvalidParams, "Boolean configuration was not negotiated")
    let options = context.connection.sessionSnapshot(request.sessionId).field("configOptions")
    validateConfigValue(parseConfigOptions(options), request.configId, request.value)
    let updated = agent.handlers.onSetConfigOption(context, request, agent.handlers.userData)
    result = %*{"configOptions": context.negotiatedOptions(updated.toJsonNode())}
  of "session/set_mode":
    if agent.handlers.onSetMode == nil: raise rpcError(MethodNotFound, "Legacy mode changes are unsupported")
    let request = parseSetMode(params)
    context.connection.requireOpenSession(request.sessionId)
    validateMode(context.connection.sessionSnapshot(request.sessionId).field("modes"), request.modeId)
    agent.handlers.onSetMode(context, request, agent.handlers.userData)
    result = newJObject()
  of "session/close":
    if agent.handlers.onCloseSession == nil: raise rpcError(MethodNotFound, "Session closing is unsupported")
    let request = parseCloseSession(params)
    if context.beginSessionClose(request.sessionId):
      if agent.handlers.onCancel != nil: agent.handlers.onCancel(request.sessionId, agent.handlers.userData)
      context.connection.cancelQueuedPrompts(request.sessionId)
      context.waitSessionHandlers(request.sessionId)
      agent.handlers.onCloseSession(context, request, agent.handlers.userData)
    result = newJObject()
  of "session/prompt":
    let request = parsePrompt(params)
    validateContent(request.prompt, (%agent.options.promptCapabilities))
    if context.isCancelled(): return PromptResponse(stopReason: cancelled).toJsonNode()
    context.connection.beginPrompt(request.sessionId)
    try:
      if context.isCancelled(): return PromptResponse(stopReason: cancelled).toJsonNode()
      var response = agent.handlers.onPrompt(context, request, agent.handlers.userData)
      if context.isCancelled(): response.stopReason = cancelled
      result = response.toJsonNode()
    finally:
      context.connection.endPrompt(request.sessionId)
  else:
    if methodName.len > 1 and methodName[0] == '_' and agent.handlers.onExtensionRequest != nil:
      return agent.handlers.onExtensionRequest(context, methodName, params, agent.handlers.userData)
    raise rpcError(MethodNotFound, "Method not found: " & methodName)

proc agentNotification(context: RequestContext, methodName: string,
    params: JsonNode) {.gcsafe.} =
  ## Forward cancellation after the reader has already signaled cancellation tokens.
  let agent = cast[AcpAgent](context.userData())
  if methodName == "session/cancel" and agent.handlers.onCancel != nil:
    agent.handlers.onCancel(params.requiredString("sessionId"), agent.handlers.userData)
  elif methodName.len > 1 and methodName[0] == '_' and agent.handlers.onExtensionNotification != nil:
    agent.handlers.onExtensionNotification(methodName, params, agent.handlers.userData)

proc newAcpAgent*(name: string, version: string, handlers: AgentHandlers,
    authMethods: seq[JsonNode] = @[], extensionCapabilities: JsonNode = nil,
    meta: JsonNode = nil, options = AgentOptions()): AcpAgent =
  ## Construct an agent around application-owned behavior and session storage.
  if handlers.onNewSession == nil or handlers.onPrompt == nil:
    raise newException(ValueError, "An agent requires session creation and prompt handlers")
  if options.systemPromptOverride and not options.systemPrompt:
    raise newException(ValueError, "System prompt override requires system prompt support")
  for authMethod in authMethods:
    let parsed = parseAuthMethod(authMethod)
    if parsed.kind notin ["agent", "terminal"]: raise newException(ValueError, "Unsupported authentication method type")
    if parsed.kind == "agent" and handlers.onAuthenticate == nil:
      raise newException(ValueError, "Agent authentication requires a handler")
  if extensionCapabilities != nil and extensionCapabilities.kind != JNull: extensionCapabilities.requireObject()
  result = cast[AcpAgent](allocShared0(sizeof(result[])))
  result.info = sharedText($(%*{"name": name, "version": version}))
  result.authMethods = sharedText($(%authMethods))
  result.extensionCapabilities = sharedText($(if extensionCapabilities == nil: newJNull() else: extensionCapabilities))
  result.meta = sharedText($(if meta == nil: newJNull() else: meta))
  result.handlers = handlers
  result.options = options

proc runStdioAgent*(agent: AcpAgent, workerThreads = DefaultWorkerThreads) =
  ## Serve the calling process's stdin/stdout until the client disconnects.
  let connection = newConnection(0, 1, agentRequest, agentNotification,
    agent, workerThreads = workerThreads)
  connection.waitClosed()
  connection.close()

proc close*(agent: AcpAgent) =
  ## Release an agent after runStdioAgent and its handlers have returned.
  freeText(agent.info)
  freeText(agent.authMethods)
  freeText(agent.extensionCapabilities)
  freeText(agent.meta)
  deallocShared(agent)
