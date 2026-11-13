import
  std/[json, locks, monotimes, options, os, osproc, strtabs, strutils, tempfiles, times, unittest],
  acport,
  acport/connection,
  ./agent_profiles

type
  Capture = object
    lock: Lock
    text: SharedText
    tools, updates, permissions, history: int
    reject: bool
    agent: TestAgent
    relay: bool

const
  TestDeadlineMs = 300_000

proc logPath(state: ptr Capture, suffix: string): string =
  ## Keep each provider/connection transcript separate for concurrent test commands.
  "build/integration-" & $state.agent & (if state.relay: "-relay-" else: "-direct-") & suffix

proc onUpdate(update: SessionUpdate, userData: pointer) {.gcsafe.} =
  ## Capture structured events and retain a diagnostic transcript for failed runs.
  let state = cast[ptr Capture](userData)
  withLock state.lock:
    inc state.updates
    if update.kind in {userMessageChunk, agentMessageChunk, agentThoughtChunk, toolCall, toolCallUpdate}:
      inc state.history
    if update.kind == toolCall: inc state.tools
    if update.kind == agentMessageChunk and update.content.kind == textContent:
      let text = localText(state.text) & update.content.text
      freeText(state.text)
      state.text = sharedText(text)
    let log = open(state.logPath("events.jsonl"), fmAppend)
    log.writeLine($update.toJsonNode())
    log.close()

proc onPermission(context: RequestContext, request: PermissionRequest,
    userData: pointer): PermissionOutcome {.gcsafe.} =
  ## Make explicit test decisions using the peer's advertised option kinds.
  let state = cast[ptr Capture](userData)
  var reject: bool
  withLock state.lock:
    inc state.permissions
    reject = state.reject
  for option in request.options:
    if option.kind == (if reject: "reject_once" else: "allow_once"):
      return PermissionOutcome(outcome: "selected", optionId: option.optionId)
  raise newException(ValueError, $state.agent & " did not offer the required permission option")

proc onLog(userData: pointer, text: string) {.gcsafe.} =
  ## Preserve adapter diagnostics without printing possible account configuration.
  let log = open(cast[ptr Capture](userData).logPath("stderr.log"), fmAppend)
  log.write(text)
  log.close()

proc connectAgent(state: ptr Capture): AcpClient =
  ## Connect to the pinned adapter directly or through the Nim agent relay.
  let command = state.agent.agentCommand()
  command.environment["ACPORT_TEST_AGENT"] = $state.agent
  result = newAcpClient("acport-integration", AcportVersion,
    ClientHandlers(onUpdate: onUpdate, onPermission: onPermission, onLog: onLog, userData: state))
  try:
    result.connect(if state.relay: absolutePath("build/agent-relay") else: command.command,
      if state.relay: @[] else: command.args, environment = command.environment)
    let info = result.initialize(60_000)
    if not state.relay: state.agent.authenticateAgent(result, info)
  except CatchableError:
    result.close()
    raise

proc resetCapture(state: ptr Capture) =
  ## Reset observations between completed turns.
  withLock state.lock:
    freeText(state.text)
    state.text = nil
    state.updates = 0
    state.tools = 0
    state.permissions = 0
    state.history = 0

proc capturedText(state: ptr Capture): string =
  ## Copy shared text into the calling thread's heap.
  withLock state.lock: result = localText(state.text)

proc observations(state: ptr Capture): tuple[updates, permissions, history: int] =
  ## Read callback counters without racing unsolicited agent updates.
  withLock state.lock: result = (state.updates, state.permissions, state.history)

proc pollPrompt(session: AcpSession, text: string): PromptResponse =
  ## Exercise non-consuming readiness against a real streaming completion.
  var turn = session.startPrompt(@[textBlock(text)])
  let started = getMonoTime()
  while not turn.isReady():
    if (getMonoTime() - started).inMilliseconds >= TestDeadlineMs:
      session.cancel()
      discard turn.waitForPrompt(60_000)
      raise newException(AcpTimeoutError, "Agent did not become ready within the test deadline")
    sleep(10)
  doAssert turn.isReady() # Repeated polling must preserve the result.
  turn.waitForPrompt(5000)

proc runLive*(agent: TestAgent, relay: bool) =
  ## Validate real turns, persisted context, permissions, and cancellation.
  let
    directory = createTempDir("acport-live-", "")
    state = cast[ptr Capture](allocShared0(sizeof(Capture)))
  initLock(state.lock)
  state.agent = agent
  state.relay = relay
  writeFile(state.logPath("events.jsonl"), "")
  writeFile(state.logPath("stderr.log"), "")
  defer:
    removeDir(directory)
    freeText(state.text)
    deinitLock(state.lock)
    deallocShared(state)
  var sessionId: string
  block:
    let client = connectAgent(state)
    defer: client.close()
    let session = client.newSession(directory, timeoutMs = 90_000, meta = agent.sessionMeta())
    sessionId = session.id
    var foundModel, foundReasoning: bool
    for option in session.getConfigOptions():
      if option.category.get("") == "model":
        discard session.setConfigOption(option.id, option.currentValue, 60_000)
        foundModel = true
      if option.category.get("") == "thought_level":
        discard session.setConfigOption(option.id, option.currentValue, 60_000)
        foundReasoning = true
    doAssert foundModel and foundReasoning, $agent & " must advertise model and reasoning settings"
    let modes = session.getModes()
    if modes.isSome:
      let modeId = if agent == claude: "default" else: modes.get().currentModeId
      session.setMode(modeId, 60_000)
      doAssert session.getModes().get().currentModeId == modeId
    else:
      doAssert agent == grok, $agent & " must expose legacy modes"
    doAssert session.pollPrompt("Remember this word for our next turn: cobalt. Reply only READY. Do not use tools.").stopReason == endTurn
    doAssert state.capturedText().contains("READY")
    doAssert state.observations().updates > 0
    state.resetCapture()
    doAssert session.prompt("What word did I ask you to remember? Reply with only that word. Do not use tools.",
      TestDeadlineMs).stopReason == endTurn
    doAssert state.capturedText().toLowerAscii().contains("cobalt")
    session.closeSession(60_000)
    state.resetCapture()
    discard client.resumeSession(sessionId, directory, timeoutMs = 90_000, meta = agent.sessionMeta())
    doAssert state.observations().history == 0, "Resume must not replay history"
    doAssert session.prompt("What word did I ask you to remember? Reply with only that word. Do not use tools.",
      TestDeadlineMs).stopReason == endTurn
    doAssert state.capturedText().toLowerAscii().contains("cobalt")
    var page = client.listSessions(cwd = some(directory), timeoutMs = 60_000)
    var found = false
    while true:
      for info in page.sessions:
        if info.sessionId == sessionId: found = true
      if found or page.nextCursor.isNone: break
      page = client.listSessions(cwd = some(directory), cursor = page.nextCursor, timeoutMs = 60_000)
    doAssert found, "Created session must appear in the filtered session list"
    state.resetCapture()
    let path = directory / "approved.txt"
    doAssert session.prompt((if agent == codex: "Use a shell command" else: "Use your file-editing tool") &
      " to write exactly ACPORT_APPROVED into " & path &
      (if agent == codex: ". The sandbox is read-only: request escalated permissions for this command. "
       else: ". Use the file-editing tool so the client can approve the write. ") &
      "This is an approval integration test. " &
      (if agent == codex: "Do not use apply_patch. " else: "Do not use a shell command. ") &
      "After writing, reply DONE.",
      TestDeadlineMs).stopReason == endTurn
    doAssert state.observations().permissions > 0
    doAssert fileExists(path)
    if fileExists(path): check readFile(path).strip() == "ACPORT_APPROVED"
    state.resetCapture()
    withLock state.lock: state.reject = true
    let rejectedPath = directory / "rejected.txt"
    doAssert session.prompt((if agent == codex: "Use a shell command" else: "Use your file-editing tool") &
      " to write exactly SHOULD_NOT_EXIST into " & rejectedPath &
      (if agent == codex: ". Request escalated permissions because the sandbox is read-only. "
       else: ". Use the file-editing tool so the client can reject the write. ") &
      "If permission is rejected, stop and reply DENIED. Do not try alternative tools.",
      TestDeadlineMs).stopReason in {endTurn, cancelled}
    doAssert state.observations().permissions > 0
    doAssert not fileExists(rejectedPath)
    withLock state.lock: state.reject = false
    state.resetCapture()
    var handle = session.startPrompt(@[textBlock("Run the shell command sleep 30 and wait for it to finish. " &
      "Do not substitute a shorter sleep. This is a cancellation integration test.")])
    let started = getMonoTime()
    var active = false
    while (getMonoTime() - started).inMilliseconds < 120_000:
      withLock state.lock: active = state.tools > 0
      if active: break
      sleep(25)
    doAssert active, $agent & " did not start a tool; cancellation was not exercised"
    session.cancel()
    doAssert handle.waitForPrompt(60_000).stopReason == cancelled
    state.resetCapture()
    doAssert session.prompt("Reply only ALIVE. Do not use tools.", TestDeadlineMs).stopReason == endTurn
    doAssert state.capturedText().contains("ALIVE")
    state.resetCapture()
    var closing = session.startPrompt(@[textBlock("Run the shell command sleep 30 and wait. Do not shorten it.")])
    let closeStarted = getMonoTime()
    var closeActive = false
    while (getMonoTime() - closeStarted).inMilliseconds < 120_000:
      withLock state.lock: closeActive = state.tools > 0
      if closeActive: break
      sleep(25)
    doAssert closeActive
    session.closeSession(60_000)
    doAssert closing.waitForPrompt(60_000).stopReason == cancelled
    let other = client.newSession(directory, timeoutMs = 90_000, meta = agent.sessionMeta())
    doAssert other.prompt("Reply only CONNECTED. Do not use tools.", TestDeadlineMs).stopReason == endTurn
    other.closeSession(60_000)
  block:
    state.resetCapture()
    let client = connectAgent(state)
    defer: client.close()
    let loaded = client.loadSession(sessionId, directory, timeoutMs = 90_000, meta = agent.sessionMeta())
    doAssert state.observations().updates > 0
    state.resetCapture()
    doAssert loaded.prompt("What word did I ask you to remember at the beginning? Reply only that word. " &
      "Do not use tools.", TestDeadlineMs).stopReason == endTurn
    doAssert state.capturedText().toLowerAscii().contains("cobalt")

proc preflight*(agent: TestAgent) =
  ## Fail rather than skip when the integration prerequisites are unavailable.
  let command = agent.agentCommand()
  doAssert command.command.len > 0 and fileExists(command.command), "Missing " & $agent & " ACP executable; see make integration-setup"
  let version = execProcess(command.command, args = @["--version"], options = {}).strip()
  case agent
  of codex:
    doAssert findExe("codex").len > 0, "An authenticated Codex CLI is required"
    doAssert version.endsWith(CodexAdapterVersion), "Expected codex-acp " & CodexAdapterVersion
  of claude:
    doAssert version == ClaudeAdapterVersion, "Expected claude-agent-acp " & ClaudeAdapterVersion
  of grok:
    doAssert version.startsWith("grok "), "Expected the native Grok Build CLI"
  echo $agent & " integration executable: " & version
