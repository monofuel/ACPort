import
  std/[json, options, os, strtabs],
  ./[connection, processes, protocol, session_protocol]

export RequestContext, LogHandler, isCancelled

type
  UpdateHandler* = proc(update: SessionUpdate, userData: pointer) {.nimcall, gcsafe.}
  PermissionHandler* = proc(context: RequestContext, request: PermissionRequest,
    userData: pointer): PermissionOutcome {.nimcall, gcsafe.}
  ClientHandlers* = object
    onUpdate*: UpdateHandler
    onPermission*: PermissionHandler
    onLog*: LogHandler
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
  AgentHandlers* = object
    onNewSession*, onLoadSession*: NewSessionHandler
    onPrompt*: PromptHandler
    onAuthenticate*: AuthenticateHandler
    onCancel*: CancelHandler
    onResumeSession*: NewSessionHandler
    onListSessions*: ListSessionsHandler
    onCloseSession*: CloseSessionHandler
    onSetConfigOption*: SetConfigOptionHandler
    onSetMode*: SetModeHandler
    userData*: pointer

  AcpClient* = ptr object
    connection: Connection
    process: ChildProcess
    info: SharedText
    handlers: ClientHandlers

  AcpAgent* = ptr object
    info, authMethods: SharedText
    handlers: AgentHandlers

  AcpSession* = object
    client*: AcpClient
    id*: string
    state*: SessionResponse

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
  let connection = session.client.requireConnection()
  defer: connection.release()
  let options = connection.sessionSnapshot(session.id).field("configOptions")
  if options.kind != JNull: result = parseConfigOptions(options)

proc getModes*(session: AcpSession): Option[SessionModeState] =
  ## Return an owned snapshot of the latest legacy mode state, when available.
  let connection = session.client.requireConnection()
  defer: connection.release()
  let modes = connection.sessionSnapshot(session.id).field("modes")
  if modes.kind != JNull: result = some(parseModes(modes))

proc getSessionInfo*(session: AcpSession): Option[SessionInfo] =
  ## Return current session metadata without activating stored sessions.
  let connection = session.client.requireConnection()
  defer: connection.release()
  let info = connection.sessionSnapshot(session.id).field("info")
  if info.field("cwd").kind == JString: result = some(parseSessionInfo(info))

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
  if params["update"].field("sessionUpdate").getStr() == "config_option_update":
    params["update"]["configOptions"] = context.negotiatedOptions(params["update"].field("configOptions"))
  context.connection.notify("session/update", params)

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

proc clientRequest(context: RequestContext, methodName: string,
    params: JsonNode): JsonNode {.gcsafe.} =
  ## Dispatch agent requests to the application's explicit permission policy.
  let client = cast[AcpClient](context.userData())
  if methodName != "session/request_permission":
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

proc clientLog(userData: pointer, text: string) {.gcsafe.} =
  ## Forward child diagnostics without mixing stderr into protocol traffic.
  let client = cast[AcpClient](userData)
  if client.handlers.onLog != nil:
    client.handlers.onLog(client.handlers.userData, text)

proc newAcpClient*(name: string, version: string,
    handlers = ClientHandlers()): AcpClient =
  ## Allocate a client; connect and close it on its owning application thread.
  result = cast[AcpClient](allocShared0(sizeof(result[])))
  result.info = sharedText($(%*{"name": name, "version": version}))
  result.handlers = handlers

proc connect*(client: AcpClient, command: string, args: seq[string] = @[],
    workingDir = "", environment: StringTableRef = nil,
    workerThreads = DefaultWorkerThreads) =
  ## Launch an agent with separate pipes and inherited environment plus overrides.
  if client.connection != nil: raise newException(AcpProtocolError, "Client is already connected")
  if workerThreads < 1: raise newException(ValueError, "At least one request worker is required")
  client.process = spawnAgent(command, args, workingDir, environment)
  try:
    client.connection = newConnection(client.process.outputFd,
      client.process.inputFd, clientRequest, clientNotification,
      client, client.process.errorFd, clientLog, workerThreads)
  except CatchableError:
    client.process.close()
    raise

proc initialize*(client: AcpClient, timeoutMs = 0): InitializeResponse =
  ## Negotiate ACP v1 without advertising unimplemented client capabilities.
  if client.connection == nil: raise newException(AcpTransportError, "Client is not connected")
  if client.connection.isInitialized(): raise newException(AcpProtocolError, "Already initialized")
  let response = client.connection.request("initialize", %*{
    "protocolVersion": ProtocolVersion,
    "clientCapabilities": {"session": {"configOptions": {"boolean": {}}}},
    "clientInfo": parseJson(localText(client.info))}, timeoutMs)
  if response.field("protocolVersion").kind != JInt or
      response["protocolVersion"].getInt() != ProtocolVersion:
    raise newException(AcpProtocolError, "Peer did not negotiate ACP v1; close this connection")
  try:
    result = decodeRecord(response, InitializeResponse)
  except AcpRpcError as error:
    raise newException(AcpProtocolError, "Invalid initialize response: " & error.msg)
  result.meta = response.field("_meta")
  client.connection.setSettings(response)
  client.connection.markInitialized()

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

proc newSession*(client: AcpClient, cwd: string,
    mcpServers: seq[JsonNode] = @[], timeoutMs = 0, meta: JsonNode = nil): AcpSession =
  ## Create an independent conversation with an absolute working directory.
  if not cwd.isAbsolute(): raise newException(ValueError, "Session cwd must be absolute")
  let connection = client.requireConnection()
  defer: connection.release()
  let
    response = connection.request("session/new",
      SessionRequest(cwd: cwd, mcpServers: mcpServers, meta: meta).toJsonNode(), timeoutMs)
    state = parseSessionResponse(response)
  connection.registerSession(state.sessionId)
  AcpSession(client: client, id: state.sessionId, state: state)

proc loadSession*(client: AcpClient, sessionId: string, cwd: string,
    mcpServers: seq[JsonNode] = @[], timeoutMs = 0, meta: JsonNode = nil): AcpSession =
  ## Load an existing session, delivering replay updates before returning.
  if not cwd.isAbsolute(): raise newException(ValueError, "Session cwd must be absolute")
  let connection = client.requireConnection()
  defer: connection.release()
  if not connection.settings().field("agentCapabilities").field("loadSession").getBool():
    raise newException(AcpProtocolError, "Peer does not support session/load")
  let state = parseSessionResponse(connection.request("session/load",
    SessionRequest(cwd: cwd, sessionId: sessionId, mcpServers: mcpServers, meta: meta).toJsonNode(true),
    timeoutMs), sessionId)
  connection.registerSession(sessionId, allowExisting = true)
  AcpSession(client: client, id: sessionId, state: state)

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
    mcpServers: seq[JsonNode] = @[], timeoutMs = 0, meta: JsonNode = nil): AcpSession =
  ## Restore a session without replaying its conversation history.
  if not cwd.isAbsolute(): raise newException(ValueError, "Session cwd must be absolute")
  let connection = client.requireConnection()
  defer: connection.release()
  connection.requireCapability("resume")
  let state = parseSessionResponse(connection.request("session/resume",
    SessionRequest(cwd: cwd, sessionId: sessionId, mcpServers: mcpServers,
      meta: meta).toJsonNode(true), timeoutMs), sessionId)
  connection.registerSession(sessionId, allowExisting = true)
  AcpSession(client: client, id: sessionId, state: state)

proc closeSession*(session: AcpSession, timeoutMs = 0, meta: JsonNode = nil) =
  ## Cancel and release one active session without deleting history or closing the client.
  let connection = session.client.requireConnection()
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
  let connection = session.client.requireConnection()
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
  let connection = session.client.requireConnection()
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
  let connection = session.client.requireConnection()
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
  let connection = session.client.requireConnection()
  defer: connection.release()
  connection.cancel(session.id)

proc isPromptActive*(session: AcpSession): bool =
  ## Check whether a cancelled or timed-out turn has received its completion yet.
  let connection = session.client.requireConnection()
  defer: connection.release()
  connection.isPromptActive(session.id)

proc close*(client: AcpClient) =
  ## Stop connection threads, reap the owned process group, and release the client.
  if client.connection != nil:
    client.connection.close()
    client.connection = nil
  client.process.close()
  freeText(client.info)
  deallocShared(client)

proc agentRequest(context: RequestContext, methodName: string,
    params: JsonNode): JsonNode {.gcsafe.} =
  ## Dispatch core agent methods with capability and session-state checks.
  let agent = cast[AcpAgent](context.userData())
  if methodName == "initialize":
    if params.field("protocolVersion").kind != JInt:
      raise rpcError(InvalidParams, "Missing protocolVersion")
    context.connection.markInitialized()
    context.connection.setSettings(params)
    var capabilities = %*{"loadSession": agent.handlers.onLoadSession != nil, "sessionCapabilities": {}}
    if agent.handlers.onListSessions != nil: capabilities["sessionCapabilities"]["list"] = newJObject()
    if agent.handlers.onResumeSession != nil: capabilities["sessionCapabilities"]["resume"] = newJObject()
    if agent.handlers.onCloseSession != nil: capabilities["sessionCapabilities"]["close"] = newJObject()
    return %*{"protocolVersion": ProtocolVersion,
      "agentInfo": parseJson(localText(agent.info)),
      "agentCapabilities": capabilities,
      "authMethods": parseJson(localText(agent.authMethods))}
  if not context.connection.isInitialized(): raise rpcError(InvalidRequest, "Not initialized")
  case methodName
  of "authenticate":
    let id = params.requiredString("methodId")
    var found = false
    for authMethod in parseJson(localText(agent.authMethods)):
      if authMethod.field("id").getStr() == id: found = true
    if agent.handlers.onAuthenticate == nil or not found:
      raise rpcError(InvalidParams, "Unsupported authentication method")
    agent.handlers.onAuthenticate(context, AuthenticateRequest(methodId: id,
      meta: params.field("_meta")), agent.handlers.userData)
    result = newJObject()
  of "session/new", "session/load", "session/resume":
    let
      load = methodName != "session/new"
      request = parseSessionRequest(params, load)
      handler = case methodName
        of "session/new": agent.handlers.onNewSession
        of "session/load": agent.handlers.onLoadSession
        else: agent.handlers.onResumeSession
    if not request.cwd.isAbsolute(): raise rpcError(InvalidParams, "Session cwd must be absolute")
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
    validateContent(request.prompt, newJObject())
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
    raise rpcError(MethodNotFound, "Method not found: " & methodName)

proc agentNotification(context: RequestContext, methodName: string,
    params: JsonNode) {.gcsafe.} =
  ## Forward cancellation after the reader has already signaled cancellation tokens.
  let agent = cast[AcpAgent](context.userData())
  if methodName == "session/cancel" and agent.handlers.onCancel != nil:
    agent.handlers.onCancel(params.requiredString("sessionId"), agent.handlers.userData)

proc newAcpAgent*(name: string, version: string, handlers: AgentHandlers,
    authMethods: seq[JsonNode] = @[]): AcpAgent =
  ## Construct an agent around application-owned behavior and session storage.
  if handlers.onNewSession == nil or handlers.onPrompt == nil:
    raise newException(ValueError, "An agent requires session creation and prompt handlers")
  if authMethods.len > 0 and handlers.onAuthenticate == nil:
    raise newException(ValueError, "Advertising authentication requires a handler")
  for authMethod in authMethods:
    discard authMethod.requiredString("id")
    discard authMethod.requiredString("name")
    if authMethod.field("type").getStr("agent") != "agent":
      raise newException(ValueError, "Only agent-managed authentication is supported")
  result = cast[AcpAgent](allocShared0(sizeof(result[])))
  result.info = sharedText($(%*{"name": name, "version": version}))
  result.authMethods = sharedText($(%authMethods))
  result.handlers = handlers

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
  deallocShared(agent)
