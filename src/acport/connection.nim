import
  std/[json, locks, monotimes, os, posix, times, unicode],
  ./[protocol, session_protocol]

type
  SharedText* = ptr object
    length: int
    bytes: UncheckedArray[char]

  RequestHandler* = proc(context: RequestContext, methodName: string,
    params: JsonNode): JsonNode {.nimcall, gcsafe.}
  NotificationHandler* = proc(context: RequestContext, methodName: string,
    params: JsonNode) {.nimcall, gcsafe.}
  LogHandler* = proc(userData: pointer, text: string) {.nimcall, gcsafe.}

  Connection* = ptr ConnectionObj
  PendingRequest* = ptr PendingObj
  Task = ptr TaskObj
  Event = ptr EventObj
  Outgoing = ptr OutgoingObj

  RequestContext* = object
    connection*: Connection
    task: Task

  TaskObj = object
    id, methodName, params, sessionId: SharedText
    cancelled: bool
    running: bool
    modeRevision: uint64
    next, activeNext: Task

  EventObj = object
    methodName, params: SharedText
    sequence: uint64
    next: Event

  OutgoingObj = object
    text: SharedText
    next: Outgoing

  PendingObj = object
    connection: Connection
    id: int
    sessionId: SharedText
    methodName, params: SharedText
    modeRevision: uint64
    abandoned: bool
    response: SharedText
    barrier: uint64
    next: PendingRequest

  Session = ptr object
    id: SharedText
    snapshot: SharedText
    known, closed, closing: bool
    modeRevision: uint64
    busy: bool
    requestId: int
    next: Session

  ConnectionObj = object
    lock: Lock
    changed: Cond
    inputFd, outputFd, errorFd: cint
    originalFlags: array[3, cint]
    closing, failed: bool
    failure: SharedText
    protocolFailure: bool
    references: int
    nextId: int
    initialized: bool
    settings: SharedText
    sessions: Session
    pending: PendingRequest
    outgoingHead, outgoingTail: Outgoing
    taskHead, taskTail, active: Task
    managementHead, managementTail: Task
    eventHead, eventTail: Event
    queued, delivered: uint64
    callbackThreadId: int
    requestHandler: RequestHandler
    notificationHandler: NotificationHandler
    logHandler: LogHandler
    userData*: pointer
    reader, writer, notifier, manager: Thread[Connection]
    workers: ptr UncheckedArray[Thread[Connection]]
    workerCount: int

const
  IoPollMs = 50
  ReadBufferSize = 16384
  DefaultWorkerThreads* = 16

proc sharedText*(text: string): SharedText =
  ## Copy text into independently owned shared memory.
  result = cast[SharedText](allocShared0(sizeof(int) + text.len))
  result.length = text.len
  if text.len > 0: copyMem(addr result.bytes[0], unsafeAddr text[0], text.len)

proc localText*(text: SharedText): string =
  ## Copy a shared buffer into the current thread's heap.
  if text != nil:
    result = newString(text.length)
    if result.len > 0: copyMem(addr result[0], addr text.bytes[0], result.len)

proc freeText*(text: SharedText) =
  ## Release an owned shared buffer.
  if text != nil: deallocShared(text)

proc destroyTask(task: Task) =
  ## Release an incoming request after its handler and response have settled.
  freeText(task.id)
  freeText(task.methodName)
  freeText(task.params)
  freeText(task.sessionId)
  deallocShared(task)

proc retain*(connection: Connection) =
  ## Keep connection state alive for an entire public API operation.
  withLock connection.lock: inc connection.references

proc release*(connection: Connection) =
  ## Free stopped connection state after its owner and pending requests release it.
  acquire(connection.lock)
  dec connection.references
  let last = connection.references == 0
  release(connection.lock)
  if last:
    var session = connection.sessions
    while session != nil:
      let next = session.next
      freeText(session.id)
      freeText(session.snapshot)
      deallocShared(session)
      session = next
    freeText(connection.failure)
    freeText(connection.settings)
    deallocShared(connection.workers)
    deinitCond(connection.changed)
    deinitLock(connection.lock)
    deallocShared(connection)

proc fail(connection: Connection, message: string, protocol = false) =
  ## Wake every waiter when a connection can no longer carry requests.
  withLock connection.lock:
    if not connection.failed or (protocol and not connection.protocolFailure):
      freeText(connection.failure)
      connection.failed = true
      connection.protocolFailure = protocol
      connection.failure = sharedText(message)
    var task = connection.active
    while task != nil:
      task.cancelled = true
      task = task.activeNext
    broadcast(connection.changed)

proc isStopped(connection: Connection): bool =
  ## Inspect connection shutdown under its state lock.
  withLock connection.lock:
    result = connection.closing or connection.failed

proc sessionLocked(connection: Connection, id: string, create = false): Session =
  ## Locate session state while the caller holds the connection lock.
  result = connection.sessions
  while result != nil:
    if localText(result.id) == id: return
    result = result.next
  if create:
    result = cast[Session](allocShared0(sizeof(result[])))
    result.id = sharedText(id)
    result.next = connection.sessions
    connection.sessions = result

proc snapshotLocked(session: Session): JsonNode =
  ## Copy a session snapshot into the locked caller's thread-local heap.
  if session != nil and session.snapshot != nil: parseJson(localText(session.snapshot))
  else: newJObject()

proc saveSnapshotLocked(session: Session, snapshot: JsonNode) =
  ## Replace a session snapshot without sharing managed JSON references.
  let text = sharedText($snapshot)
  freeText(session.snapshot)
  session.snapshot = text

proc applyUpdateLocked(connection: Connection, params: JsonNode) =
  ## Apply state-bearing notifications in the same order as the wire stream.
  let
    id = params.requiredString("sessionId")
    update = params.field("update")
    kind = update.field("sessionUpdate").getStr()
  if kind notin ["config_option_update", "current_mode_update", "session_info_update"]: return
  let
    session = connection.sessionLocked(id, true)
    snapshot = session.snapshotLocked()
  case kind
  of "config_option_update":
    discard parseConfigOptions(update.field("configOptions"))
    snapshot["configOptions"] = update["configOptions"]
  of "current_mode_update":
    let mode = update.requiredString("currentModeId")
    if snapshot.field("modes").kind != JObject:
      snapshot["modes"] = %*{"availableModes": []}
    snapshot["modes"]["currentModeId"] = %mode
    inc session.modeRevision
  of "session_info_update":
    if snapshot.field("info").kind != JObject: snapshot["info"] = %*{"sessionId": id}
    for key in ["title", "updatedAt", "_meta"]:
      if update.hasKey(key): snapshot["info"][key] = update[key]
  else: discard
  session.saveSnapshotLocked(snapshot)

proc applyResponseLocked(connection: Connection, methodName: string, params,
    response: JsonNode, modeRevision: uint64) =
  ## Apply received response metadata before waking callers or delivering callbacks.
  if methodName == "session/list":
    discard parseListSessionsResponse(response)
    for info in response["sessions"]:
      let
        session = connection.sessionLocked(info.requiredString("sessionId"), true)
        snapshot = session.snapshotLocked()
      snapshot["info"] = info
      session.saveSnapshotLocked(snapshot)
    return
  if methodName notin ["session/new", "session/load", "session/resume",
      "session/set_config_option", "session/set_mode", "session/close"]: return
  let
    id = if methodName == "session/new": response.requiredString("sessionId")
      else: params.requiredString("sessionId")
    session = connection.sessionLocked(id, true)
    snapshot = session.snapshotLocked()
  if methodName in ["session/new", "session/load", "session/resume"]:
    for key in ["configOptions", "modes"]:
      if response.hasKey(key):
        if response[key].kind != JNull:
          if key == "modes": discard parseModes(response[key])
          else: discard parseConfigOptions(response[key])
        snapshot[key] = response[key]
        if key == "modes": inc session.modeRevision
    if snapshot.field("info").kind != JObject: snapshot["info"] = newJObject()
    snapshot["info"]["sessionId"] = %id
    snapshot["info"]["cwd"] = params.field("cwd")
    session.closed = false
    session.closing = false
  elif methodName == "session/set_config_option":
    discard parseConfigOptions(response.field("configOptions"))
    snapshot["configOptions"] = response["configOptions"]
  elif methodName == "session/set_mode":
    if session.modeRevision == modeRevision and snapshot.field("modes").kind == JObject:
      snapshot["modes"]["currentModeId"] = params.field("modeId")
  else:
    session.closed = true
    session.closing = false
    session.busy = false
  session.saveSnapshotLocked(snapshot)

proc sessionSnapshot*(connection: Connection, id: string): JsonNode =
  ## Return an independently owned current-state snapshot, including closed history.
  withLock connection.lock:
    let session = connection.sessionLocked(id)
    if session == nil: raise rpcError(SessionNotFound, "Unknown session: " & id)
    result = session.snapshotLocked()

proc requireOpenSession*(connection: Connection, id: string) =
  ## Reject operations on unknown, closed, or closing sessions.
  withLock connection.lock:
    let session = connection.sessionLocked(id)
    if session == nil or not session.known or session.closed or session.closing:
      raise rpcError(SessionNotFound, "Session is not active: " & id)

proc sessionIsClosed*(connection: Connection, id: string): bool =
  ## Test whether a previously closed session has already completed cleanup.
  withLock connection.lock:
    let session = connection.sessionLocked(id)
    result = session != nil and session.closed

proc markSessionClosing*(connection: Connection, id: string) =
  ## Prevent copied session handles from starting new work during closure.
  withLock connection.lock:
    let session = connection.sessionLocked(id, true)
    if not session.closed: session.closing = true

proc beginSessionClose*(context: RequestContext, id: string): bool =
  ## Cancel session work before application cleanup, without cancelling the close itself.
  let connection = context.connection
  withLock connection.lock:
    let session = connection.sessionLocked(id)
    if session == nil or not session.known or session.closed: return false
    session.closing = true
    var task = connection.active
    while task != nil:
      if task != context.task and localText(task.sessionId) == id and
          localText(task.methodName) != "session/close": task.cancelled = true
      task = task.activeNext
    broadcast(connection.changed)
    result = true

proc waitSessionHandlers*(context: RequestContext, id: string) =
  ## Wait until running session handlers have returned and their responses are queued.
  let connection = context.connection
  acquire(connection.lock)
  while true:
    var
      task = connection.active
      running = false
    while task != nil:
      if task != context.task and task.running and localText(task.sessionId) == id:
        running = true
      task = task.activeNext
    if not running: break
    wait(connection.changed, connection.lock)
  release(connection.lock)

proc enqueue(connection: Connection, node: JsonNode) =
  ## Queue a complete JSON-RPC message for the sole pipe writer.
  let outgoing = cast[Outgoing](allocShared0(sizeof(OutgoingObj)))
  let text = $node & "\n"
  if validateUtf8(text) >= 0:
    deallocShared(outgoing)
    raise newException(AcpProtocolError, "Outgoing JSON must be UTF-8")
  outgoing.text = sharedText(text)
  try:
    withLock connection.lock:
      if connection.closing or connection.failed:
        raise newException(AcpTransportError, "Connection is closed")
      if node.field("method").getStr() == "session/update":
        connection.applyUpdateLocked(node.field("params"))
      elif node.hasKey("result"):
        var task = connection.active
        while task != nil:
          if localText(task.id) == $node.field("id"):
            connection.applyResponseLocked(localText(task.methodName), parseJson(localText(task.params)),
              node["result"], task.modeRevision)
            break
          task = task.activeNext
      if connection.outgoingTail == nil: connection.outgoingHead = outgoing
      else: connection.outgoingTail.next = outgoing
      connection.outgoingTail = outgoing
      broadcast(connection.changed)
  except CatchableError:
    freeText(outgoing.text)
    deallocShared(outgoing)
    raise

proc notify*(connection: Connection, methodName: string, params: JsonNode) =
  ## Send a notification with no request identifier.
  connection.enqueue(%*{"jsonrpc": "2.0", "method": methodName, "params": params})

proc cancelQueuedPrompts*(connection: Connection, id: string) =
  ## Settle queued turns during close even when every prompt worker is occupied.
  var removed: Task
  withLock connection.lock:
    var link = addr connection.taskHead
    while link[] != nil:
      let task = link[]
      if localText(task.sessionId) == id and localText(task.methodName) == "session/prompt":
        link[] = task.next
        var activeLink = addr connection.active
        while activeLink[] != task: activeLink = addr activeLink[].activeNext
        activeLink[] = task.activeNext
        task.next = removed
        removed = task
      else:
        link = addr task.next
    connection.taskTail = connection.taskHead
    while connection.taskTail != nil and connection.taskTail.next != nil:
      connection.taskTail = connection.taskTail.next
  while removed != nil:
    let task = removed
    removed = task.next
    try:
      connection.enqueue(%*{"jsonrpc": "2.0", "id": parseJson(localText(task.id)),
        "result": {"stopReason": "cancelled"}})
    except AcpTransportError:
      discard # Continue freeing detached tasks after disconnect.
    finally:
      destroyTask(task)

proc isCancelled*(context: RequestContext): bool =
  ## Inspect cooperative cancellation without blocking protocol I/O.
  withLock context.connection.lock:
    result = context.connection.closing or context.connection.failed or
      (context.task != nil and context.task.cancelled)

proc userData*(context: RequestContext): pointer =
  ## Return application-owned context registered before the connection starts.
  context.connection.userData

proc cancelSession*(connection: Connection, sessionId: string) =
  ## Signal session handlers and wake permission waiters immediately.
  withLock connection.lock:
    var task = connection.active
    while task != nil:
      if localText(task.sessionId) == sessionId: task.cancelled = true
      task = task.activeNext
    broadcast(connection.changed)

proc cancel*(connection: Connection, sessionId: string) =
  ## Cancel a peer session without terminating the underlying connection.
  connection.cancelSession(sessionId)
  connection.notify("session/cancel", %*{"sessionId": sessionId})

proc startRequest*(connection: Connection, methodName: string,
    params: JsonNode): PendingRequest =
  ## Start a request whose response may be collected on another application thread.
  result = cast[PendingRequest](allocShared0(sizeof(PendingObj)))
  result.connection = connection
  result.sessionId = sharedText(params.field("sessionId").getStr())
  result.methodName = sharedText(methodName)
  result.params = sharedText($params)
  withLock connection.lock:
    if connection.closing or connection.failed:
      freeText(result.sessionId)
      freeText(result.methodName)
      freeText(result.params)
      deallocShared(result)
      raise newException(AcpTransportError, "Connection is closed")
    inc connection.nextId
    result.id = connection.nextId
    result.next = connection.pending
    connection.pending = result
    inc connection.references
    let session = connection.sessionLocked(params.field("sessionId").getStr())
    if session != nil: result.modeRevision = session.modeRevision
    if methodName == "session/prompt":
      var session = connection.sessions
      while session != nil:
        if localText(session.id) == localText(result.sessionId): session.requestId = result.id
        session = session.next
  try:
    connection.enqueue(%*{"jsonrpc": "2.0", "id": result.id,
      "method": methodName, "params": params})
  except CatchableError as error:
    connection.fail(error.msg, error of AcpProtocolError or error of AcpRpcError)

proc timedWait(connection: Connection, milliseconds: int) =
  ## Sleep on the state condition, with an optional bounded wakeup.
  if milliseconds <= 0:
    wait(connection.changed, connection.lock)
  else:
    var deadline: Timespec
    discard clock_gettime(CLOCK_REALTIME, deadline)
    deadline.tv_nsec += clong(milliseconds mod 1000) * 1_000_000
    deadline.tv_sec = posix.Time(clong(deadline.tv_sec) + milliseconds div 1000 + int(deadline.tv_nsec div 1_000_000_000))
    deadline.tv_nsec = deadline.tv_nsec mod 1_000_000_000
    let code = pthread_cond_timedwait(cast[ptr Pthread_cond](addr connection.changed),
      cast[ptr Pthread_mutex](addr connection.lock), addr deadline)
    if code != 0 and code != ETIMEDOUT: raiseOSError(OSErrorCode(code))

proc destroyPending(pending: PendingRequest) =
  ## Release an owned pending record after it is removed from the routing list.
  freeText(pending.sessionId)
  freeText(pending.methodName)
  freeText(pending.params)
  freeText(pending.response)
  deallocShared(pending)

proc waitResponse*(pending: PendingRequest, timeoutMs = 0,
    context = RequestContext()): JsonNode =
  ## Consume a pending request once, after all preceding update callbacks finish.
  let
    connection = pending.connection
    started = getMonoTime()
  connection.retain()
  defer: connection.release()
  var
    response, failure: string
    expired, interrupted, protocolFailure: bool
  acquire(connection.lock)
  if connection.callbackThreadId == getThreadId():
    failure = "Update callbacks cannot wait on their own connection; use startPrompt"
    protocolFailure = true
  while true:
    if failure.len > 0: break
    if connection.closing:
      failure = "Connection closed"
      break
    if connection.failed and connection.protocolFailure:
      failure = localText(connection.failure)
      protocolFailure = true
      break
    if pending.response != nil and connection.delivered >= pending.barrier:
      response = localText(pending.response)
      break
    if (connection.failed or connection.closing) and pending.response == nil:
      failure = if connection.failure != nil: localText(connection.failure) else: "Connection closed"
      protocolFailure = connection.protocolFailure
      break
    if context.task != nil and context.task.cancelled:
      interrupted = true
      break
    if timeoutMs > 0 and (getMonoTime() - started).inMilliseconds >= timeoutMs:
      expired = true
      break
    connection.timedWait(if timeoutMs > 0: min(timeoutMs, IoPollMs) else: 0)
  let
    abandon = (expired or interrupted) and pending.response == nil and
      not connection.closing and not connection.failed
    requestId = pending.id
    sessionId = localText(pending.sessionId)
    promptRequest = localText(pending.methodName) == "session/prompt"
  if abandon:
    pending.abandoned = true
  else:
    var link = addr connection.pending
    while link[] != pending: link = addr link[].next
    link[] = pending.next
  release(connection.lock)
  if expired or interrupted:
    try:
      connection.notify("$/cancel_request", %*{"requestId": requestId})
      if expired and promptRequest and sessionId.len > 0:
        connection.cancel(sessionId)
    except AcpTransportError:
      discard # The connection may have closed after the waiter woke up.
  if not abandon:
    destroyPending(pending)
    connection.release()
  if expired: raise newException(AcpTimeoutError, "ACP request deadline expired")
  if interrupted: raise newException(AcpCancelledError, "ACP request cancelled")
  if failure.len > 0:
    if protocolFailure: raise newException(AcpProtocolError, failure)
    raise newException(AcpTransportError, failure)
  let node = parseJson(response)
  if node.hasKey("error"):
    let error = node["error"]
    raise rpcError(error.field("code").getInt(), error.requiredString("message"), error.field("data"))
  node["result"]

proc request*(connection: Connection, methodName: string, params: JsonNode,
    timeoutMs = 0, context = RequestContext()): JsonNode =
  ## Make a blocking request while background threads service the connection.
  waitResponse(connection.startRequest(methodName, params), timeoutMs, context)

proc settings*(connection: Connection): JsonNode =
  ## Copy connection metadata into the calling thread.
  withLock connection.lock:
    let text = localText(connection.settings)
    result = if text.len > 0: parseJson(text) else: newJObject()

proc setSettings*(connection: Connection, settings: JsonNode) =
  ## Replace negotiated metadata without sharing managed JSON between threads.
  let text = sharedText($settings)
  withLock connection.lock:
    freeText(connection.settings)
    connection.settings = text

proc isInitialized*(connection: Connection): bool =
  ## Inspect handshake state under the connection lock.
  withLock connection.lock: result = connection.initialized

proc markInitialized*(connection: Connection) =
  ## Complete initialization once per connection.
  withLock connection.lock:
    if connection.initialized: raise rpcError(InvalidRequest, "Already initialized")
    connection.initialized = true

proc registerSession*(connection: Connection, sessionId: string, allowExisting = false) =
  ## Register a session after successful creation or loading.
  if sessionId.len == 0: raise rpcError(InvalidParams, "Empty session identifier")
  withLock connection.lock:
    let session = connection.sessionLocked(sessionId, true)
    if session.known and not allowExisting:
      raise newException(AcpProtocolError, "Duplicate session identifier: " & sessionId)
    session.known = true

proc beginPrompt*(connection: Connection, sessionId: string) =
  ## Claim the sole active prompt slot for a known session.
  withLock connection.lock:
    var session = connection.sessions
    while session != nil:
      if localText(session.id) == sessionId:
        if not session.known or session.closed or session.closing:
          raise rpcError(SessionNotFound, "Session is not active: " & sessionId)
        if session.busy: raise rpcError(InvalidRequest, "Session already has an active prompt")
        session.busy = true
        return
      session = session.next
    raise rpcError(SessionNotFound, "Unknown session: " & sessionId)

proc endPrompt*(connection: Connection, sessionId: string) =
  ## Release a session's active prompt slot.
  withLock connection.lock:
    var session = connection.sessions
    while session != nil:
      if localText(session.id) == sessionId:
        session.busy = false
        session.requestId = 0
        return
      session = session.next

proc isPromptActive*(connection: Connection, sessionId: string): bool =
  ## Inspect whether a session still awaits its prompt completion.
  withLock connection.lock:
    var session = connection.sessions
    while session != nil:
      if localText(session.id) == sessionId: return session.busy and not session.closed
      session = session.next

proc sendError(connection: Connection, id: JsonNode, code: int, message: string,
    data: JsonNode = nil) =
  ## Send a JSON-RPC error preserving the original request identifier.
  var error = %*{"code": code, "message": message}
  if data != nil and data.kind != JNull: error["data"] = data
  connection.enqueue(%*{"jsonrpc": "2.0", "id": id, "error": error})

proc queueEvent(connection: Connection, methodName: string, params: string) =
  ## Transfer callback input without sharing thread-local managed strings.
  let event = cast[Event](allocShared0(sizeof(EventObj)))
  event.methodName = sharedText(methodName)
  event.params = sharedText(params)
  withLock connection.lock:
    if connection.closing or connection.failed:
      freeText(event.methodName)
      freeText(event.params)
      deallocShared(event)
      return
    inc connection.queued
    event.sequence = connection.queued
    if connection.eventTail == nil: connection.eventHead = event
    else: connection.eventTail.next = event
    connection.eventTail = event
    broadcast(connection.changed)

proc handleLine(connection: Connection, line: string) =
  ## Route one independently framed JSON-RPC message.
  var node: JsonNode
  if validateUtf8(line) >= 0:
    connection.sendError(newJNull(), ParseError, "Invalid UTF-8")
    return
  try:
    node = parseJson(line)
  except JsonParsingError:
    connection.sendError(newJNull(), ParseError, "Invalid JSON")
    return
  if node.kind != JObject or node.field("jsonrpc").getStr() != "2.0":
    connection.sendError(newJNull(), InvalidRequest, "Expected a JSON-RPC 2.0 object")
    return
  if node.hasKey("id") and node["id"].kind notin {JNull, JInt, JString}:
    connection.sendError(newJNull(), InvalidRequest, "Invalid request identifier")
    return
  if node.hasKey("method"):
    if node["method"].kind != JString:
      if node.hasKey("id"): connection.sendError(node["id"], InvalidRequest, "Invalid method")
      return
    let
      methodName = node["method"].getStr()
      params = node.field("params")
    if not node.hasKey("id"):
      if methodName == "session/update":
        withLock connection.lock: connection.applyUpdateLocked(params)
      if methodName == "session/cancel":
        connection.cancelSession(params.field("sessionId").getStr())
      elif methodName == "$/cancel_request":
        withLock connection.lock:
          var task = connection.active
          while task != nil:
            if localText(task.id) == $params.field("requestId"): task.cancelled = true
            task = task.activeNext
          broadcast(connection.changed)
      if methodName == "session/update" or methodName == "session/cancel":
        connection.queueEvent(methodName, $params)
    else:
      let task = cast[Task](allocShared0(sizeof(TaskObj)))
      task.id = sharedText($node["id"])
      task.methodName = sharedText(methodName)
      task.params = sharedText($params)
      task.sessionId = sharedText(params.field("sessionId").getStr())
      withLock connection.lock:
        if connection.closing or connection.failed:
          freeText(task.id)
          freeText(task.methodName)
          freeText(task.params)
          freeText(task.sessionId)
          deallocShared(task)
          return
        task.activeNext = connection.active
        connection.active = task
        let session = connection.sessionLocked(params.field("sessionId").getStr())
        if session != nil: task.modeRevision = session.modeRevision
        if methodName in ["session/new", "session/load", "session/resume", "session/list",
            "session/close", "session/set_mode", "session/set_config_option"]:
          if connection.managementTail == nil: connection.managementHead = task
          else: connection.managementTail.next = task
          connection.managementTail = task
        else:
          if connection.taskTail == nil: connection.taskHead = task
          else: connection.taskTail.next = task
          connection.taskTail = task
        broadcast(connection.changed)
  elif node.hasKey("id"):
    if node.hasKey("result") == node.hasKey("error"):
      connection.fail("Response must contain exactly one of result or error", true)
      return
    if node.hasKey("error") and (node["error"].field("code").kind != JInt or
        node["error"].field("message").kind != JString):
      connection.fail("Malformed JSON-RPC error response", true)
      return
    var abandoned: PendingRequest
    withLock connection.lock:
      var session = connection.sessions
      while session != nil:
        if node["id"].kind == JInt and session.requestId > 0 and
            session.requestId == node["id"].getInt():
          session.busy = false
          session.requestId = 0
        session = session.next
      var pending = connection.pending
      while pending != nil:
        if node["id"].kind == JInt and pending.id == node["id"].getInt():
          let methodName = localText(pending.methodName)
          if node.hasKey("result"):
            connection.applyResponseLocked(methodName, parseJson(localText(pending.params)),
              node["result"], pending.modeRevision)
          elif methodName == "session/close" and node["error"].field("code").getInt() == SessionNotFound:
            let session = connection.sessionLocked(localText(pending.sessionId), true)
            session.closed = true
            session.closing = false
            session.busy = false
          if pending.response != nil:
            connection.failed = true
            connection.protocolFailure = true
            connection.failure = sharedText("Duplicate response identifier")
          else:
            pending.response = sharedText(line)
            pending.barrier = connection.queued
          if pending.abandoned:
            var link = addr connection.pending
            while link[] != pending: link = addr link[].next
            link[] = pending.next
            abandoned = pending
          broadcast(connection.changed)
          break
        pending = pending.next
    if abandoned != nil:
      destroyPending(abandoned)
      connection.release()
  else:
    connection.sendError(newJNull(), InvalidRequest, "Invalid JSON-RPC message")

proc blockSigpipe() =
  ## Keep a closed peer pipe from terminating the hosting application.
  var signals, previous: Sigset
  discard sigemptyset(signals)
  discard sigaddset(signals, SIGPIPE)
  discard pthread_sigmask(SIG_BLOCK, signals, previous)

proc writerThread(connection: Connection) {.thread.} =
  ## Serialize outgoing messages and stop even when the peer stops reading.
  blockSigpipe()
  try:
    while true:
      acquire(connection.lock)
      while connection.outgoingHead == nil and not connection.closing and not connection.failed:
        wait(connection.changed, connection.lock)
      let outgoing = connection.outgoingHead
      if outgoing != nil:
        connection.outgoingHead = outgoing.next
        if connection.outgoingHead == nil: connection.outgoingTail = nil
      let stopped = connection.closing or connection.failed
      release(connection.lock)
      if outgoing == nil: break
      let text = localText(outgoing.text)
      freeText(outgoing.text)
      deallocShared(outgoing)
      if stopped: continue
      var position = 0
      while position < text.len and not connection.isStopped():
        var fd = TPollfd(fd: connection.outputFd, events: POLLOUT)
        let ready = posix.poll(addr fd, 1, IoPollMs)
        if ready < 0:
          if errno == EINTR: continue
          raiseOSError(osLastError())
        if ready == 0: continue
        let count = posix.write(connection.outputFd, unsafeAddr text[position], text.len - position)
        if count < 0:
          if errno in [EAGAIN, EINTR]: continue
          raiseOSError(osLastError())
        position += count
  except CatchableError as error:
    connection.fail(error.msg)

proc readerThread(connection: Connection) {.thread.} =
  ## Incrementally frame stdout and independently drain stderr.
  try:
    var
      pending = ""
      errorFd = connection.errorFd
    while not connection.isStopped():
      var descriptors = [TPollfd(fd: connection.inputFd, events: POLLIN),
        TPollfd(fd: errorFd, events: POLLIN)]
      let ready = posix.poll(addr descriptors[0], 2, IoPollMs)
      if ready < 0:
        if errno == EINTR: continue
        raiseOSError(osLastError())
      if ready == 0: continue
      for i in 0 .. 1:
        if descriptors[i].revents == 0: continue
        var buffer = newString(ReadBufferSize)
        let count = posix.read(descriptors[i].fd, addr buffer[0], buffer.len)
        if count < 0:
          if errno in [EAGAIN, EINTR]: continue
          raiseOSError(osLastError())
        if count == 0:
          if i == 0:
            connection.fail(if pending.len > 0: "EOF inside ACP message" else: "Peer closed stdout",
              pending.len > 0)
            return
          errorFd = -1
          continue
        buffer.setLen(count)
        if i == 1:
          if connection.logHandler != nil: connection.queueEvent("$/stderr", buffer)
        else:
          pending.add(buffer)
          var start = 0
          for position in 0 ..< pending.len:
            if pending[position] == '\n':
              connection.handleLine(pending[start ..< position])
              start = position + 1
          if start > 0: pending = pending[start .. ^1]
  except CatchableError as error:
    connection.fail(error.msg, error of AcpProtocolError or error of AcpRpcError)

proc notifierThread(connection: Connection) {.thread.} =
  ## Deliver ordered callbacks without running application code on the I/O thread.
  withLock connection.lock: connection.callbackThreadId = getThreadId()
  while true:
    acquire(connection.lock)
    while connection.eventHead == nil and not connection.closing and not connection.failed:
      wait(connection.changed, connection.lock)
    let event = connection.eventHead
    if event != nil:
      connection.eventHead = event.next
      if connection.eventHead == nil: connection.eventTail = nil
    release(connection.lock)
    if event == nil: break
    try:
      if localText(event.methodName) == "$/stderr":
        connection.logHandler(connection.userData, localText(event.params))
      elif connection.notificationHandler != nil:
        connection.notificationHandler(RequestContext(connection: connection),
          localText(event.methodName), parseJson(localText(event.params)))
    except CatchableError as error:
      connection.fail("Notification callback failed: " & error.msg, true)
    withLock connection.lock:
      connection.delivered = event.sequence
      broadcast(connection.changed)
    freeText(event.methodName)
    freeText(event.params)
    deallocShared(event)

proc workerLoop(connection: Connection, management: bool) {.gcsafe.} =
  ## Execute blocking request handlers independently of routing and callbacks.
  while true:
    acquire(connection.lock)
    let
      head = if management: addr connection.managementHead else: addr connection.taskHead
      tail = if management: addr connection.managementTail else: addr connection.taskTail
    while head[] == nil and not connection.closing and not connection.failed:
      wait(connection.changed, connection.lock)
    let task = head[]
    if task != nil:
      head[] = task.next
      if head[] == nil: tail[] = nil
      task.running = true
    release(connection.lock)
    if task == nil: break
    let context = RequestContext(connection: connection, task: task)
    try:
      if connection.requestHandler == nil:
        raise rpcError(MethodNotFound, "Method not found")
      let response = connection.requestHandler(context,
        localText(task.methodName), parseJson(localText(task.params)))
      connection.enqueue(%*{"jsonrpc": "2.0", "id": parseJson(localText(task.id)), "result": response})
    except AcpRpcError as error:
      try: connection.sendError(parseJson(localText(task.id)), error.code, error.msg, error.data)
      except AcpTransportError: discard # No reply can be delivered after disconnect.
    except CatchableError as error:
      try: connection.sendError(parseJson(localText(task.id)), InternalError, error.msg)
      except AcpTransportError: discard # No reply can be delivered after disconnect.
    withLock connection.lock:
      var link = addr connection.active
      while link[] != task: link = addr link[].activeNext
      link[] = task.activeNext
      broadcast(connection.changed)
    destroyTask(task)

proc workerThread(connection: Connection) {.thread.} =
  ## Service ordinary requests and long-running prompts.
  workerLoop(connection, false)

proc managementThread(connection: Connection) {.thread.} =
  ## Keep lifecycle and configuration requests independent of occupied prompt workers.
  workerLoop(connection, true)

proc newConnection*(inputFd, outputFd: cint, requestHandler: RequestHandler,
    notificationHandler: NotificationHandler, userData: pointer = nil,
    errorFd: cint = -1, logHandler: LogHandler = nil,
    workerThreads = DefaultWorkerThreads): Connection =
  ## Start a Linux stdio connection over caller-owned file descriptors.
  if workerThreads < 1: raise newException(ValueError, "At least one request worker is required")
  result = cast[Connection](allocShared0(sizeof(ConnectionObj)))
  initLock(result.lock)
  initCond(result.changed)
  result.references = 1
  result.inputFd = inputFd
  result.outputFd = outputFd
  result.errorFd = errorFd
  result.requestHandler = requestHandler
  result.notificationHandler = notificationHandler
  result.logHandler = logHandler
  result.userData = userData
  var
    notifierStarted, writerStarted, managerStarted: bool
    flagsChanged = 0
  try:
    for index, fd in [inputFd, outputFd, errorFd]:
      result.originalFlags[index] = -1
      if fd >= 0:
        let flags = fcntl(fd, F_GETFL)
        if flags < 0: raiseOSError(osLastError())
        result.originalFlags[index] = flags
        if fcntl(fd, F_SETFL, flags or O_NONBLOCK) < 0: raiseOSError(osLastError())
      inc flagsChanged
    result.workers = cast[ptr UncheckedArray[Thread[Connection]]](
      allocShared0(workerThreads * sizeof(Thread[Connection])))
    for i in 0 ..< workerThreads:
      createThread(result.workers[i], workerThread, result)
      inc result.workerCount
    createThread(result.manager, managementThread, result)
    managerStarted = true
    createThread(result.notifier, notifierThread, result)
    notifierStarted = true
    createThread(result.writer, writerThread, result)
    writerStarted = true
    createThread(result.reader, readerThread, result)
  except CatchableError:
    withLock result.lock:
      result.closing = true
      broadcast(result.changed)
    if writerStarted: joinThread(result.writer)
    if notifierStarted: joinThread(result.notifier)
    if managerStarted: joinThread(result.manager)
    for i in 0 ..< result.workerCount: joinThread(result.workers[i])
    for index, fd in [inputFd, outputFd, errorFd]:
      if index < flagsChanged and fd >= 0: discard fcntl(fd, F_SETFL, result.originalFlags[index])
    result.release()
    raise

proc waitClosed*(connection: Connection) =
  ## Block until EOF, a transport failure, or an explicit close request.
  acquire(connection.lock)
  while not connection.closing and not connection.failed:
    wait(connection.changed, connection.lock)
  release(connection.lock)

proc close*(connection: Connection) =
  ## Stop and join background threads; outstanding handles retain failure state.
  withLock connection.lock:
    connection.closing = true
    var task = connection.active
    while task != nil:
      task.cancelled = true
      task = task.activeNext
    broadcast(connection.changed)
  joinThread(connection.reader)
  joinThread(connection.writer)
  joinThread(connection.notifier)
  joinThread(connection.manager)
  for i in 0 ..< connection.workerCount: joinThread(connection.workers[i])
  withLock connection.lock:
    var link = addr connection.pending
    while link[] != nil:
      let pending = link[]
      if pending.abandoned:
        link[] = pending.next
        destroyPending(pending)
        dec connection.references
      else:
        link = addr pending.next
  for index, fd in [connection.inputFd, connection.outputFd, connection.errorFd]:
    if fd >= 0: discard fcntl(fd, F_SETFL, connection.originalFlags[index])
  connection.release()
