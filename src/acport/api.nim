import
  std/[json, os, strtabs],
  ./[connection, processes, protocol]

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
  AgentHandlers* = object
    onNewSession*, onLoadSession*: NewSessionHandler
    onPrompt*: PromptHandler
    onAuthenticate*: AuthenticateHandler
    onCancel*: CancelHandler
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

proc sendUpdate*(context: RequestContext, update: SessionUpdate) =
  ## Stream a structured session update from a request handler.
  context.connection.notify("session/update", update.toJsonNode())

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
  if client.handlers.onPermission != nil:
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
    "protocolVersion": ProtocolVersion, "clientCapabilities": {},
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

proc authenticate*(client: AcpClient, methodId: string, timeoutMs = 0) =
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
  discard connection.request("authenticate", %*{"methodId": methodId}, timeoutMs)

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
    return %*{"protocolVersion": ProtocolVersion,
      "agentInfo": parseJson(localText(agent.info)),
      "agentCapabilities": {"loadSession": agent.handlers.onLoadSession != nil},
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
    agent.handlers.onAuthenticate(context, AuthenticateRequest(methodId: id), agent.handlers.userData)
    result = newJObject()
  of "session/new", "session/load":
    let
      load = methodName == "session/load"
      request = parseSessionRequest(params, load)
      handler = if load: agent.handlers.onLoadSession else: agent.handlers.onNewSession
    if not request.cwd.isAbsolute(): raise rpcError(InvalidParams, "Session cwd must be absolute")
    if handler == nil: raise rpcError(MethodNotFound, "Method not found: " & methodName)
    var response = handler(context, request, agent.handlers.userData)
    if load: response.sessionId = request.sessionId
    context.connection.registerSession(response.sessionId, allowExisting = load)
    result = response.toJsonNode(load)
  of "session/prompt":
    let request = parsePrompt(params)
    validateContent(request.prompt, newJObject())
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
