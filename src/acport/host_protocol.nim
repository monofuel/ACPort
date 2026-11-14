import
  std/[json, options, os],
  ./protocol

type
  ReadTextFileRequest* = object
    sessionId*, path*: string
    line*, limit*: Option[uint32]
    meta*, raw*: JsonNode
  ReadTextFileResponse* = object
    content*: string
    meta*, raw*: JsonNode
  WriteTextFileRequest* = object
    sessionId*, path*, content*: string
    meta*, raw*: JsonNode
  WriteTextFileResponse* = EmptyMessage
  EnvVariable* = object
    name*, value*: string
    meta*, raw*: JsonNode
  CreateTerminalRequest* = object
    sessionId*, command*: string
    args*: seq[string]
    env*: seq[EnvVariable]
    cwd*: Option[string]
    outputByteLimit*: Option[uint64]
    meta*, raw*: JsonNode
  CreateTerminalResponse* = object
    terminalId*: string
    meta*, raw*: JsonNode
  TerminalRequest* = object
    sessionId*, terminalId*: string
    meta*, raw*: JsonNode
  TerminalOutputRequest* = TerminalRequest
  WaitForTerminalExitRequest* = TerminalRequest
  KillTerminalRequest* = TerminalRequest
  ReleaseTerminalRequest* = TerminalRequest
  TerminalExitStatus* = object
    exitCode*: Option[uint32]
    signal*: Option[string]
    meta*, raw*: JsonNode
  WaitForTerminalExitResponse* = TerminalExitStatus
  TerminalOutputResponse* = object
    output*: string
    truncated*: bool
    exitStatus*: Option[TerminalExitStatus]
    meta*, raw*: JsonNode
  KillTerminalResponse* = EmptyMessage
  ReleaseTerminalResponse* = EmptyMessage

proc attachMeta(node: JsonNode, meta: JsonNode) =
  ## Attach supplied protocol metadata.
  if meta != nil and meta.kind != JNull: node["_meta"] = meta

proc optionalUint32(node: JsonNode, key: string): Option[uint32] =
  ## Decode a nullable uint32 without narrowing an out-of-range integer.
  let value = optionalUnsigned(node, key, high(uint32))
  if value.isSome: result = some(uint32(value.get()))

proc optionalText(node: JsonNode, key: string): Option[string] =
  ## Decode a nullable string while rejecting malformed supplied values.
  let value = node.field(key)
  if value.kind == JString: result = some(value.getStr())
  elif value.kind != JNull: raise rpcError(InvalidParams, "Expected optional string: " & key)

proc absolutePath(node: JsonNode, key: string): string =
  ## Validate an absolute protocol path without accessing the filesystem.
  result = node.requiredString(key)
  if not result.isAbsolute(): raise rpcError(InvalidParams, "Expected absolute path: " & key)

proc parseReadTextFileRequest*(node: JsonNode): ReadTextFileRequest =
  ## Decode a host-buffer read with optional one-based line and line count.
  result = ReadTextFileRequest(sessionId: node.requiredString("sessionId"),
    path: node.absolutePath("path"), line: optionalUint32(node, "line"),
    limit: optionalUint32(node, "limit"), meta: node.field("_meta"), raw: node)
  if result.line.isSome and result.line.get() == 0:
    raise rpcError(InvalidParams, "Read line is one-based")

proc toJsonNode*(request: ReadTextFileRequest): JsonNode =
  ## Encode a host-buffer read without inventing read limits.
  if request.raw != nil: return request.raw
  result = %*{"sessionId": request.sessionId, "path": request.path}
  if request.line.isSome: result["line"] = %request.line.get()
  if request.limit.isSome: result["limit"] = %request.limit.get()
  result.attachMeta(request.meta)

proc parseReadTextFileResponse*(node: JsonNode): ReadTextFileResponse =
  ## Decode host-provided text and retain response extensions.
  ReadTextFileResponse(content: node.requiredString("content"), meta: node.field("_meta"), raw: node)

proc toJsonNode*(response: ReadTextFileResponse): JsonNode =
  ## Encode text read from a file or unsaved host buffer.
  if response.raw != nil: return response.raw
  result = %*{"content": response.content}
  result.attachMeta(response.meta)

proc parseWriteTextFileRequest*(node: JsonNode): WriteTextFileRequest =
  ## Decode a complete text replacement without applying an access policy.
  WriteTextFileRequest(sessionId: node.requiredString("sessionId"), path: node.absolutePath("path"),
    content: node.requiredString("content"), meta: node.field("_meta"), raw: node)

proc toJsonNode*(request: WriteTextFileRequest): JsonNode =
  ## Encode a host-controlled text replacement.
  if request.raw != nil: return request.raw
  result = %*{"sessionId": request.sessionId, "path": request.path, "content": request.content}
  result.attachMeta(request.meta)

proc parseCreateTerminalRequest*(node: JsonNode): CreateTerminalRequest =
  ## Decode a command invocation without shell interpolation or process execution.
  result = CreateTerminalRequest(sessionId: node.requiredString("sessionId"),
    command: node.requiredString("command"), cwd: optionalText(node, "cwd"),
    outputByteLimit: optionalUnsigned(node, "outputByteLimit"), meta: node.field("_meta"), raw: node)
  if result.cwd.isSome and not result.cwd.get().isAbsolute():
    raise rpcError(InvalidParams, "Terminal cwd must be absolute")
  let args = node.field("args")
  if args.kind != JNull:
    if args.kind != JArray: raise rpcError(InvalidParams, "Expected args array")
    for arg in args:
      if arg.kind != JString: raise rpcError(InvalidParams, "Expected string argument")
      result.args.add(arg.getStr())
  let env = node.field("env")
  if env.kind != JNull:
    if env.kind != JArray: raise rpcError(InvalidParams, "Expected env array")
    for entry in env:
      result.env.add(EnvVariable(name: entry.requiredString("name"), value: entry.requiredString("value"),
        meta: entry.field("_meta"), raw: entry))

proc toJsonNode*(request: CreateTerminalRequest): JsonNode =
  ## Encode a structured command and its environment overrides.
  if request.raw != nil: return request.raw
  result = %*{"sessionId": request.sessionId, "command": request.command, "args": request.args, "env": []}
  for entry in request.env:
    var node = entry.raw
    if node == nil:
      node = %*{"name": entry.name, "value": entry.value}
      node.attachMeta(entry.meta)
    result["env"].add(node)
  if request.cwd.isSome: result["cwd"] = %request.cwd.get()
  if request.outputByteLimit.isSome: result["outputByteLimit"] = %request.outputByteLimit.get()
  result.attachMeta(request.meta)

proc parseCreateTerminalResponse*(node: JsonNode): CreateTerminalResponse =
  ## Decode the identifier of an already-started terminal.
  CreateTerminalResponse(terminalId: node.requiredString("terminalId"), meta: node.field("_meta"), raw: node)

proc toJsonNode*(response: CreateTerminalResponse): JsonNode =
  ## Encode a terminal identifier without waiting for process exit.
  if response.raw != nil: return response.raw
  result = %*{"terminalId": response.terminalId}
  result.attachMeta(response.meta)

proc parseTerminalRequest*(node: JsonNode): TerminalRequest =
  ## Decode a terminal operation scoped to one session.
  TerminalRequest(sessionId: node.requiredString("sessionId"), terminalId: node.requiredString("terminalId"),
    meta: node.field("_meta"), raw: node)

proc toJsonNode*(request: TerminalRequest): JsonNode =
  ## Encode a session-scoped terminal reference.
  if request.raw != nil: return request.raw
  result = %*{"sessionId": request.sessionId, "terminalId": request.terminalId}
  result.attachMeta(request.meta)

proc parseTerminalExitStatus*(node: JsonNode): TerminalExitStatus =
  ## Decode normal or signal-based termination without inventing an exit code.
  node.requireObject()
  TerminalExitStatus(exitCode: optionalUint32(node, "exitCode"), signal: optionalText(node, "signal"),
    meta: node.field("_meta"), raw: node)

proc toJsonNode*(status: TerminalExitStatus): JsonNode =
  ## Encode nullable process termination details.
  if status.raw != nil: return status.raw
  result = newJObject()
  if status.exitCode.isSome: result["exitCode"] = %status.exitCode.get()
  if status.signal.isSome: result["signal"] = %status.signal.get()
  result.attachMeta(status.meta)

proc parseTerminalOutputResponse*(node: JsonNode): TerminalOutputResponse =
  ## Decode a nonblocking output snapshot with optional completion status.
  result = TerminalOutputResponse(output: node.requiredString("output"), meta: node.field("_meta"), raw: node)
  if node.field("truncated").kind != JBool: raise rpcError(InvalidParams, "Expected truncated boolean")
  result.truncated = node["truncated"].getBool()
  if node.field("exitStatus").kind != JNull:
    result.exitStatus = some(parseTerminalExitStatus(node["exitStatus"]))

proc toJsonNode*(response: TerminalOutputResponse): JsonNode =
  ## Encode a terminal snapshot without clearing retained host output.
  if response.raw != nil: return response.raw
  result = %*{"output": response.output, "truncated": response.truncated}
  if response.exitStatus.isSome: result["exitStatus"] = response.exitStatus.get().toJsonNode()
  result.attachMeta(response.meta)
