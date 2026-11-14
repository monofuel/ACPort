import
  std/[locks, options, os, posix, strtabs, strutils, unicode],
  acport,
  acport/[connection, processes]

type
  TestTerminal = ptr object
    id, sessionId, output: SharedText
    child: ChildProcess
    limit: uint64
    bounded, truncated, finished, released: bool
    exitCode: cint
    signal: cint
    next: TestTerminal
  TestHost* = ptr object
    lock: Lock
    root: SharedText
    terminals: TestTerminal
    nextId, waits: int

proc newTestHost*(root: string): TestHost =
  ## Allocate test-only host state without sharing managed objects across workers.
  result = cast[TestHost](allocShared0(sizeof(result[])))
  initLock(result.lock)
  result.root = sharedText(root)

proc close*(host: TestHost) =
  ## Reap all fixture children after the owning ACP connection has joined its workers.
  var terminal = host.terminals
  while terminal != nil:
    let next = terminal.next
    if not terminal.finished: discard posix.kill(-terminal.child.pid, SIGKILL)
    terminal.child.close()
    freeText(terminal.id)
    freeText(terminal.sessionId)
    freeText(terminal.output)
    deallocShared(terminal)
    terminal = next
  freeText(host.root)
  deinitLock(host.lock)
  deallocShared(host)

proc checkedPath(host: TestHost, path: string): string =
  ## Constrain fixture file requests to the test's temporary directory.
  result = path.normalizedPath()
  if not result.startsWith(localText(host.root) & "/"):
    raise rpcError(-32001, "Outside fixture root")

proc readText(context: RequestContext, request: ReadTextFileRequest, data: pointer): ReadTextFileResponse {.gcsafe.} =
  ## Prefer a synthetic unsaved editor buffer, then apply one-based line slicing.
  let path = cast[TestHost](data).checkedPath(request.path)
  let text = if path.endsWith("/unsaved.txt"): "α\nbuffer\nthree\n" else: readFile(path)
  if request.line.isNone and request.limit.isNone: result.content = text
  else:
    let lines = text.splitLines()
    let start = if request.line.isSome: int(request.line.get()) - 1 else: 0
    let limit = if request.limit.isSome: int(request.limit.get()) else: lines.len
    let stop = min(lines.len, start + limit)
    if start < stop: result.content = lines[start ..< stop].join("\n")
  result.meta = request.meta

proc writeText(context: RequestContext, request: WriteTextFileRequest, data: pointer): WriteTextFileResponse {.gcsafe.} =
  ## Write only inside the explicitly allocated fixture root.
  writeFile(cast[TestHost](data).checkedPath(request.path), request.content)
  result.meta = request.meta

proc lookup(host: TestHost, request: TerminalRequest): TestTerminal =
  ## Find an unreleased terminal under the host lock and enforce session ownership.
  result = host.terminals
  while result != nil:
    if localText(result.id) == request.terminalId and not result.released and
        localText(result.sessionId) == request.sessionId: return
    result = result.next
  raise rpcError(InvalidParams, "Unknown terminal for session")

proc sync(terminal: TestTerminal) =
  ## Drain available pipe output and reap exit status without blocking the management worker.
  var output = localText(terminal.output)
  for fd in [terminal.child.outputFd, terminal.child.errorFd]:
    while true:
      var buffer: array[4096, char]
      let count = posix.read(fd, addr buffer[0], buffer.len)
      if count <= 0: break
      let offset = output.len
      output.setLen(offset + count)
      copyMem(addr output[offset], addr buffer[0], count)
  if not terminal.finished:
    var status: cint
    if waitpid(terminal.child.pid, status, WNOHANG) == terminal.child.pid:
      terminal.finished = true
      if WIFEXITED(status): terminal.exitCode = WEXITSTATUS(status)
      elif WIFSIGNALED(status): terminal.signal = WTERMSIG(status)
  if terminal.bounded and uint64(output.len) > terminal.limit:
    var offset = output.len - int(terminal.limit)
    while offset < output.len and (uint8(output[offset]) and 0xc0) == 0x80: inc offset
    output = output[offset ..< output.len]
    terminal.truncated = true
  freeText(terminal.output)
  terminal.output = sharedText(output)

proc status(terminal: TestTerminal): TerminalExitStatus =
  ## Preserve normal and signal-based termination as distinct protocol values.
  if terminal.signal != 0: result.signal = some($terminal.signal)
  else: result.exitCode = some(uint32(terminal.exitCode))

proc create(context: RequestContext, request: CreateTerminalRequest, data: pointer): CreateTerminalResponse {.gcsafe.} =
  ## Launch a real Linux fixture process and return without waiting for exit.
  let host = cast[TestHost](data)
  var env = newStringTable(modeCaseSensitive)
  for entry in request.env: env[entry.name] = entry.value
  var child = spawnAgent(request.command, request.args, request.cwd.get(""), env)
  for fd in [child.outputFd, child.errorFd]:
    discard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) or O_NONBLOCK)
  let terminal = cast[TestTerminal](allocShared0(sizeof(host.terminals[])))
  terminal.child = child
  terminal.sessionId = sharedText(request.sessionId)
  terminal.bounded = request.outputByteLimit.isSome
  terminal.limit = request.outputByteLimit.get(0)
  withLock host.lock:
    inc host.nextId
    result.terminalId = "terminal-" & $host.nextId
    terminal.id = sharedText(result.terminalId)
    terminal.next = host.terminals
    host.terminals = terminal
  result.meta = request.meta

proc output(context: RequestContext, request: TerminalRequest, data: pointer): TerminalOutputResponse {.gcsafe.} =
  ## Return a nonconsuming snapshot from the fixture's retained terminal output.
  let host = cast[TestHost](data)
  withLock host.lock:
    let terminal = host.lookup(request)
    terminal.sync()
    result.output = localText(terminal.output)
    let invalid = validateUtf8(result.output)
    if invalid >= 0: result.output.setLen(invalid)
    result.truncated = terminal.truncated
    if terminal.finished: result.exitStatus = some(terminal.status())
  result.meta = request.meta

proc waitExit(context: RequestContext, request: TerminalRequest, data: pointer): TerminalExitStatus {.gcsafe.} =
  ## Poll only the fixture process, leaving kill and release to explicit control requests.
  let host = cast[TestHost](data)
  withLock host.lock: inc host.waits
  defer:
    withLock host.lock: dec host.waits
  while true:
    if context.isCancelled(): raise newException(AcpCancelledError, "Fixture wait cancelled")
    withLock host.lock:
      let terminal = host.lookup(request)
      terminal.sync()
      if terminal.finished:
        result = terminal.status()
        result.meta = request.meta
        return
    sleep(5)

proc kill(context: RequestContext, request: TerminalRequest, data: pointer): EmptyMessage {.gcsafe.} =
  ## Kill the fixture group without releasing its output or terminal identity.
  let host = cast[TestHost](data)
  withLock host.lock:
    let terminal = host.lookup(request)
    terminal.sync()
    if not terminal.finished: discard posix.kill(-terminal.child.pid, SIGTERM)
  result.meta = request.meta

proc release(context: RequestContext, request: TerminalRequest, data: pointer): EmptyMessage {.gcsafe.} =
  ## Stop and invalidate the terminal while retaining its record until callbacks have joined.
  let host = cast[TestHost](data)
  withLock host.lock:
    let terminal = host.lookup(request)
    terminal.sync()
    if not terminal.finished: discard posix.kill(-terminal.child.pid, SIGKILL)
    terminal.released = true
  result.meta = request.meta

proc handlers*(host: TestHost): ClientHandlers =
  ## Provide a complete filesystem and terminal bundle for deterministic and live tests.
  ClientHandlers(onReadTextFile: readText, onWriteTextFile: writeText, onCreateTerminal: create,
    onTerminalOutput: output, onWaitForTerminalExit: waitExit, onKillTerminal: kill,
    onReleaseTerminal: release, userData: host)

proc activeWaits*(host: TestHost): int =
  ## Observe worker occupancy for bounded concurrency assertions.
  withLock host.lock: result = host.waits
