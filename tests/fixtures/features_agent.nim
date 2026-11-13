import
  std/[json, locks, options, os],
  acport,
  acport/connection

type State = object
  lock: Lock
  nextId, notifications: int

proc create(context: RequestContext, request: SessionRequest, data: pointer): SessionResponse {.gcsafe.} =
  ## Publish initial events before setup completes to exercise ghost-session caching.
  let state = cast[ptr State](data)
  withLock state.lock:
    inc state.nextId
    result.sessionId = "feature-" & $state.nextId
  context.sendUpdate(availableCommandsUpdate(result.sessionId, @[
    AvailableCommand(name: "inspect", description: "Inspect", input: some(AvailableCommandInput(hint: "path")))]))
  context.sendUpdate(usageUpdate(result.sessionId, UsageUpdate(used: 12, size: 200,
    cost: some(UsageCost(amount: 0.25, currency: "credits")))))

proc formRequest(sessionId: string): ElicitationRequest =
  ## Keep form data opaque, including an application-specific schema extension.
  ElicitationRequest(mode: formElicitation, sessionId: sessionId,
    toolCallId: some("question-tool"), message: "Pick a color",
    requestedSchema: %*{"type":"object", "properties":{"color":{"type":"string", "enum":["cobalt", "red"]}},
      "_meta":{"schema":"opaque"}})

proc runPrompt(context: RequestContext, request: PromptRequest, data: pointer): PromptResponse {.gcsafe.} =
  ## Exercise both new directions, live events and cooperative nested interactions.
  let text = request.prompt[0].text
  case text
  of "events":
    context.sendUpdate(availableCommandsUpdate(request.sessionId, @[]))
    context.sendUpdate(usageUpdate(request.sessionId, UsageUpdate(used: 0, size: 0)))
  of "extension":
    context.notifyExtension("_client_event", %*{"nested":[true, 7], "_meta":{"event":1}})
    let response = context.requestExtension("_client_echo", %*{"nested":[true, 7]}, 5000)
    context.sendUpdate(SessionUpdate(sessionId: request.sessionId, kind: agentMessageChunk, content: textBlock($response)))
  of "form", "slow-form":
    let response = context.requestElicitation(formRequest(request.sessionId), 5000)
    context.sendUpdate(SessionUpdate(sessionId: request.sessionId, kind: agentMessageChunk,
      content: textBlock($response.toJsonNode())))
  of "url", "url-background":
    let response = context.requestElicitation(ElicitationRequest(mode: urlElicitation,
      sessionId: request.sessionId, message: "Open only after consent", url: "https://example.invalid/acport-test",
      elicitationId: "flow-" & request.sessionId), 5000)
    if text == "url" and response.action == acceptElicitation:
      context.completeElicitation("flow-" & request.sessionId, %*{"complete":true})
  else: discard
  PromptResponse(stopReason: if context.isCancelled(): cancelled else: endTurn)

proc authenticate(context: RequestContext, request: AuthenticateRequest, data: pointer) {.gcsafe.} =
  ## Ask a request-scoped question before the first session exists.
  var form = formRequest("")
  form.scope = requestElicitationScope
  form.toolCallId = none(string)
  let response = context.requestElicitation(form, 5000)
  if response.action != acceptElicitation: raise rpcError(AuthRequired, "Form not accepted")

proc extension(context: RequestContext, name: string, params: JsonNode, data: pointer): JsonNode {.gcsafe.} =
  ## Keep custom payloads opaque and expose deliberate errors/deadlines.
  case name
  of "_echo": result = params
  of "_caps": result = context.connection.settings()
  of "_rpc-error": raise rpcError(-32001, "Extension error", %*{"detail":[1, true]})
  of "_count":
    let state = cast[ptr State](data)
    withLock state.lock: result = %state.notifications
  of "_complete":
    context.completeElicitation(params.requiredString("elicitationId"))
    result = newJObject()
  of "_duplicate":
    try:
      discard context.requestElicitation(ElicitationRequest(mode: urlElicitation,
        sessionId: params.requiredString("sessionId"), elicitationId: params.requiredString("elicitationId"),
        message: "Duplicate", url: "https://example.invalid/duplicate"), 5000)
      result = %false
    except AcpRpcError: result = %true
  of "_wait":
    while not context.isCancelled(): sleep(5)
    result = %*{"cancelled":true}
  else:
    if name.len > 0 and name[0] != '_': return %*{"incorrectlyIntercepted":true}
    raise rpcError(MethodNotFound, "Unknown extension")

proc notification(name: string, params: JsonNode, data: pointer) {.gcsafe.} =
  ## Count extension notifications on the ordered callback thread.
  let state = cast[ptr State](data)
  withLock state.lock: inc state.notifications

proc closeSession(context: RequestContext, request: CloseSessionRequest, data: pointer) {.gcsafe.} =
  ## Let the runtime coordinate cancellation before a trivial cleanup hook.
  discard

proc main() =
  ## Serve feature tests using a bounded prompt pool and an independent manager.
  let state = cast[ptr State](allocShared0(sizeof(State)))
  initLock(state.lock)
  defer:
    deinitLock(state.lock)
    deallocShared(state)
  let agent = newAcpAgent("features", "1", AgentHandlers(onNewSession: create, onPrompt: runPrompt,
    onAuthenticate: authenticate, onCloseSession: closeSession, onExtensionRequest: extension,
    onExtensionNotification: notification, userData: state),
    @[%*{"id":"form-auth", "name":"Form auth"}], extensionCapabilities = %*{"feature":true}, meta = %*{"agent":1})
  defer: agent.close()
  agent.runStdioAgent(workerThreads = 1)

main()
