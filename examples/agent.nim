import
  std/atomics,
  acport

type
  AgentState = object
    nextSession: Atomic[int]

proc createSession(context: RequestContext, request: SessionRequest,
    userData: pointer): SessionResponse {.gcsafe.} =
  ## Create a unique in-memory session without advertising persistence.
  let state = cast[ptr AgentState](userData)
  SessionResponse(sessionId: "echo-" & $(state.nextSession.fetchAdd(1) + 1))

proc echo(context: RequestContext, request: PromptRequest,
    userData: pointer): PromptResponse {.gcsafe.} =
  ## Echo supported text content while honoring cooperative cancellation.
  for content in request.prompt:
    if context.isCancelled(): return PromptResponse(stopReason: cancelled)
    if content.kind == textContent:
      context.sendUpdate(SessionUpdate(sessionId: request.sessionId,
        kind: agentMessageChunk, content: content))
  PromptResponse(stopReason: endTurn)

proc main() =
  ## Serve an ACP agent using application-supplied behavior.
  let state = cast[ptr AgentState](allocShared0(sizeof(AgentState)))
  defer: deallocShared(state)
  let agent = newAcpAgent("echo", AcportVersion,
    AgentHandlers(onNewSession: createSession, onPrompt: echo, userData: state))
  defer: agent.close()
  agent.runStdioAgent()

main()
