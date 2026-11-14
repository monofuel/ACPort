import
  std/[json, strtabs],
  ./protocol

type
  AuthMethod* = object
    id*, name*, description*, kind*: string
    args*: seq[string]
    env*, meta*, raw*: JsonNode
  TerminalAuthInvocation* = object
    methodInfo*: AuthMethod
    command*, workingDir*: string
    args*: seq[string]
    environment*: StringTableRef
  LogoutRequest* = EmptyMessage
  LogoutResponse* = EmptyMessage

proc parseAuthMethod*(node: JsonNode): AuthMethod =
  ## Decode agent or terminal authentication without accepting an agent-supplied executable.
  result = AuthMethod(id: node.requiredString("id"), name: node.requiredString("name"),
    description: node.field("description").getStr(), kind: node.field("type").getStr("agent"),
    env: node.field("env"), meta: node.field("_meta"), raw: node)
  if result.kind notin ["agent", "terminal"]: return
  if result.kind == "terminal":
    let args = node.field("args")
    if args.kind != JNull:
      if args.kind != JArray: raise rpcError(InvalidParams, "Expected terminal authentication args array")
      for arg in args:
        if arg.kind != JString: raise rpcError(InvalidParams, "Expected authentication argument string")
        result.args.add(arg.getStr())
    if result.env.kind != JNull:
      result.env.requireObject()
      for key, value in result.env:
        if value.kind != JString: raise rpcError(InvalidParams, "Expected authentication environment string: " & key)

proc toJsonNode*(methodInfo: AuthMethod): JsonNode =
  ## Encode an authentication descriptor, retaining unknown received variants.
  if methodInfo.raw != nil: return methodInfo.raw
  result = %*{"id": methodInfo.id, "name": methodInfo.name}
  if methodInfo.kind.len > 0: result["type"] = %methodInfo.kind
  if methodInfo.description.len > 0: result["description"] = %methodInfo.description
  if methodInfo.kind == "terminal":
    result["args"] = %methodInfo.args
    if methodInfo.env != nil: result["env"] = methodInfo.env
  if methodInfo.meta != nil and methodInfo.meta.kind != JNull: result["_meta"] = methodInfo.meta
