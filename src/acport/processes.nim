import
  std/[monotimes, os, posix, strtabs, times]

type
  ChildProcess* = object
    pid*: Pid
    inputFd*, outputFd*, errorFd*: cint
    exited: bool

const
  ShutdownGraceMs = 3000

proc pipeCloseOnExec(fds: var array[2, cint], flags: cint): cint
  {.importc: "pipe2", header: "<unistd.h>".}

proc spawnChdir(actions: var Tposix_spawn_file_actions, directory: cstring): cint
  {.importc: "posix_spawn_file_actions_addchdir_np", header: "<spawn.h>".}

proc check(code: cint) =
  ## Convert POSIX spawn return codes into operating-system exceptions.
  if code != 0: raiseOSError(OSErrorCode(code))

proc spawnAgent*(command: string, args: seq[string], workingDir: string,
    overrides: StringTableRef): ChildProcess =
  ## Spawn with child-only cwd changes, separate pipes, and a dedicated process group.
  var
    pipes: array[3, array[2, cint]]
    opened = 0
    actions: Tposix_spawn_file_actions
    attributes: Tposix_spawnattr
  defer:
    for i in 0 ..< opened:
      for fd in pipes[i]:
        if fd >= 0: discard posix.close(fd)
  for i in 0 .. 2:
    if pipeCloseOnExec(pipes[i], O_CLOEXEC) != 0: raiseOSError(osLastError())
    inc opened
    for endpoint in 0 .. 1:
      if pipes[i][endpoint] < 3:
        let moved = fcntl(pipes[i][endpoint], F_DUPFD_CLOEXEC, 3)
        if moved < 0: raiseOSError(osLastError())
        discard posix.close(pipes[i][endpoint])
        pipes[i][endpoint] = moved
  check posix_spawn_file_actions_init(actions)
  defer: discard posix_spawn_file_actions_destroy(actions)
  check posix_spawnattr_init(attributes)
  defer: discard posix_spawnattr_destroy(attributes)
  check posix_spawn_file_actions_adddup2(actions, pipes[0][0], 0)
  check posix_spawn_file_actions_adddup2(actions, pipes[1][1], 1)
  check posix_spawn_file_actions_adddup2(actions, pipes[2][1], 2)
  if workingDir.len > 0: check spawnChdir(actions, workingDir.cstring)
  var mask: Sigset
  discard sigemptyset(mask)
  check posix_spawnattr_setsigmask(attributes, mask)
  check posix_spawnattr_setpgroup(attributes, 0)
  check posix_spawnattr_setflags(attributes, POSIX_SPAWN_SETPGROUP or POSIX_SPAWN_SETSIGMASK)
  var environment = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): environment[key] = value
  if overrides != nil:
    for key, value in overrides: environment[key] = value
  var values: seq[string]
  for key, value in environment: values.add(key & "=" & value)
  let
    argv = allocCStringArray(@[command] & args)
    envp = allocCStringArray(values)
  defer:
    deallocCStringArray(argv)
    deallocCStringArray(envp)
  check posix_spawnp(result.pid, command.cstring, actions, attributes, argv, envp)
  result.inputFd = pipes[0][1]
  result.outputFd = pipes[1][0]
  result.errorFd = pipes[2][0]
  pipes[0][1] = -1
  pipes[1][0] = -1
  pipes[2][0] = -1

proc waitUntil(child: var ChildProcess, timeoutMs: int): bool =
  ## Reap the owned child within a monotonic deadline.
  if child.exited: return true
  let started = getMonoTime()
  while true:
    var status: cint
    let resultPid = waitpid(child.pid, status, WNOHANG)
    if resultPid == child.pid or (resultPid < 0 and errno == ECHILD):
      child.exited = true
      return true
    if resultPid < 0 and errno != EINTR: raiseOSError(osLastError())
    if (getMonoTime() - started).inMilliseconds >= timeoutMs: return false
    sleep(10)

proc close*(child: var ChildProcess) =
  ## Close stdin, allow graceful exit, then terminate the owned process group if needed.
  if child.pid == 0: return
  discard posix.close(child.inputFd)
  child.inputFd = -1
  if not child.waitUntil(ShutdownGraceMs):
    discard posix.kill(-child.pid, SIGTERM)
    if not child.waitUntil(ShutdownGraceMs):
      discard posix.kill(-child.pid, SIGKILL)
      var status: cint
      while waitpid(child.pid, status, 0) < 0:
        if errno != EINTR: break
      child.exited = true
  discard posix.close(child.outputFd)
  discard posix.close(child.errorFd)
  child.pid = 0
