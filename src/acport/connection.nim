import
  std/[json, locks, monotimes, os, posix, times, unicode],
  ./protocol

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
    response: SharedText
    barrier: uint64
    next: PendingRequest

  Session = ptr object
    id: SharedText
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
    eventHead, eventTail: Event
    queued, delivered: uint64
    callbackThreadId: int
    requestHandler: RequestHandler
    notificationHandler: NotificationHandler
    logHandler: LogHandler
    userData*: pointer
    reader, writer, notifier: Thread[Connection]
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

proc enqueue(connection: Connection, node: JsonNode) =
  ## Queue a complete JSON-RPC message for the sole pipe writer.
  let outgoing = cast[Outgoing](allocShared0(sizeof(OutgoingObj)))
  let text = $node & "\n"
  if validateUtf8(text) >= 0:
    deallocShared(outgoing)
    raise newException(AcpProtocolError, "Outgoing JSON must be UTF-8")
  outgoing.text = sharedText(text)
  withLock connection.lock:
    if connection.closing or connection.failed:
      freeText(outgoing.text)
      deallocShared(outgoing)
      raise newException(AcpTransportError, "Connection is closed")
    if connection.outgoingTail == nil: connection.outgoingHead = outgoing
    else: connection.outgoingTail.next = outgoing
    connection.outgoingTail = outgoing
    broadcast(connection.changed)

proc notify*(connection: Connection, methodName: string, params: JsonNode) =
  ## Send a notification with no request identifier.
  connection.enqueue(%*{"jsonrpc": "2.0", "method": methodName, "params": params})

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
  withLock connection.lock:
    if connection.closing or connection.failed:
      freeText(result.sessionId)
      deallocShared(result)
      raise newException(AcpTransportError, "Connection is closed")
    inc connection.nextId
    result.id = connection.nextId
    result.next = connection.pending
    connection.pending = result
    inc connection.references
    if methodName == "session/prompt":
      var session = connection.sessions
      while session != nil:
        if localText(session.id) == localText(result.sessionId): session.requestId = result.id
        session = session.next
  try:
    connection.enqueue(%*{"jsonrpc": "2.0", "id": result.id,
      "method": methodName, "params": params})
  except CatchableError as error:
    connection.fail(error.msg, error of AcpProtocolError)

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

proc waitResponse*(pending: PendingRequest, timeoutMs = 0,
    context = RequestContext()): JsonNode =
  ## Consume a pending request once, after all preceding update callbacks finish.
  let
    connection = pending.connection
    started = getMonoTime()
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
  var link = addr connection.pending
  while link[] != pending: link = addr link[].next
  link[] = pending.next
  release(connection.lock)
  if expired or interrupted:
    try:
      connection.notify("$/cancel_request", %*{"requestId": pending.id})
      if expired and localText(pending.sessionId).len > 0:
        connection.cancel(localText(pending.sessionId))
    except AcpTransportError:
      discard # The connection may have closed after the waiter woke up.
  freeText(pending.sessionId)
  freeText(pending.response)
  deallocShared(pending)
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
    var session = connection.sessions
    while session != nil:
      if localText(session.id) == sessionId:
        if allowExisting: return
        raise newException(AcpProtocolError, "Duplicate session identifier: " & sessionId)
      session = session.next
    session = cast[Session](allocShared0(sizeof(session[])))
    session.id = sharedText(sessionId)
    session.next = connection.sessions
    connection.sessions = session

proc beginPrompt*(connection: Connection, sessionId: string) =
  ## Claim the sole active prompt slot for a known session.
  withLock connection.lock:
    var session = connection.sessions
    while session != nil:
      if localText(session.id) == sessionId:
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
      if localText(session.id) == sessionId: return session.busy
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
          if pending.response != nil:
            connection.failed = true
            connection.protocolFailure = true
            connection.failure = sharedText("Duplicate response identifier")
          else:
            pending.response = sharedText(line)
            pending.barrier = connection.queued
          broadcast(connection.changed)
          break
        pending = pending.next
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
    connection.fail(error.msg, error of AcpProtocolError)

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

proc workerThread(connection: Connection) {.thread.} =
  ## Execute blocking request handlers independently of routing and callbacks.
  while true:
    acquire(connection.lock)
    while connection.taskHead == nil and not connection.closing and not connection.failed:
      wait(connection.changed, connection.lock)
    let task = connection.taskHead
    if task != nil:
      connection.taskHead = task.next
      if connection.taskHead == nil: connection.taskTail = nil
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
    freeText(task.id)
    freeText(task.methodName)
    freeText(task.params)
    freeText(task.sessionId)
    deallocShared(task)

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
    notifierStarted, writerStarted: bool
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
  for i in 0 ..< connection.workerCount: joinThread(connection.workers[i])
  for index, fd in [connection.inputFd, connection.outputFd, connection.errorFd]:
    if fd >= 0: discard fcntl(fd, F_SETFL, connection.originalFlags[index])
  connection.release()
