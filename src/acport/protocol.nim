import
  std/[json, options],
  jsony

type
  AcpError* = object of CatchableError
  AcpProtocolError* = object of AcpError
  AcpTransportError* = object of AcpError
  AcpTimeoutError* = object of AcpError
  AcpCancelledError* = object of AcpError
  AcpRpcError* = object of AcpError
    code*: int
    data*: JsonNode

  Implementation* = object
    name*: string
    version*: string
    title*: Option[string]

  PromptCapabilities* = object
    image*, audio*, embeddedContext*: bool

  AgentCapabilities* = object
    loadSession*: bool
    promptCapabilities*: PromptCapabilities

  InitializeRequest* = object
    protocolVersion*: int
    clientCapabilities*: JsonNode
    clientInfo*: Implementation

  InitializeResponse* = object
    protocolVersion*: int
    agentCapabilities*: JsonNode
    authMethods*: seq[JsonNode]
    agentInfo*: Option[Implementation]
    meta*: JsonNode

  AuthenticateRequest* = object
    methodId*: string

  SessionRequest* = object
    cwd*: string
    mcpServers*: seq[JsonNode]
    sessionId*: string
    meta*: JsonNode

  SessionResponse* = object
    sessionId*: string
    modes*, configOptions*, meta*: JsonNode

  ContentKind* = enum
    textContent, resourceLinkContent, imageContent, audioContent,
    resourceContent, unknownContent

  ContentBlock* = object
    kind*: ContentKind
    text*, uri*, name*, data*, mimeType*: string
    resource*, annotations*, meta*, raw*: JsonNode

  PromptRequest* = object
    sessionId*: string
    prompt*: seq[ContentBlock]
    meta*: JsonNode

  StopReason* = enum
    endTurn, maxTokens, maxTurnRequests, refused, cancelled

  PromptResponse* = object
    stopReason*: StopReason
    meta*: JsonNode

  FileDiff* = object
    path*: string
    oldText*: Option[string]
    newText*: string

  ToolContentKind* = enum
    blockToolContent, diffToolContent, terminalToolContent, unknownToolContent

  ToolContent* = object
    kind*: ToolContentKind
    content*: ContentBlock
    diff*: FileDiff
    terminalId*: string
    raw*: JsonNode

  ToolLocation* = object
    path*: string
    line*: Option[int]

  ToolCall* = object
    toolCallId*, title*, name*, kind*, status*: string
    content*: Option[seq[ToolContent]]
    locations*: Option[seq[ToolLocation]]
    rawInput*, rawOutput*, meta*, raw*: JsonNode

  PlanEntry* = object
    content*, priority*, status*: string

  UpdateKind* = enum
    userMessageChunk, agentMessageChunk, agentThoughtChunk, toolCall,
    toolCallUpdate, planUpdate, unknownUpdate

  SessionUpdate* = object
    sessionId*: string
    kind*: UpdateKind
    content*: ContentBlock
    tool*: ToolCall
    entries*: seq[PlanEntry]
    messageId*: string
    meta*, outerMeta*, raw*: JsonNode

  PermissionOption* = object
    optionId*, name*, kind*: string
    meta*, raw*: JsonNode

  PermissionRequest* = object
    sessionId*: string
    toolCall*: ToolCall
    options*: seq[PermissionOption]
    meta*: JsonNode

  PermissionOutcome* = object
    outcome*: string
    optionId*: string

const
  AcportVersion* = "1.0.0"
  ProtocolVersion* = 1
  SchemaRevision* = "c392d7e9d1de01337b749c0070929933e9f6f09f"
  ParseError* = -32700
  InvalidRequest* = -32600
  MethodNotFound* = -32601
  InvalidParams* = -32602
  InternalError* = -32603
  SessionNotFound* = -32002
  AuthRequired* = -32000

proc rpcError*(code: int, message: string, data: JsonNode = nil): ref AcpRpcError =
  ## Construct an RPC exception without losing the peer's error data.
  result = newException(AcpRpcError, message)
  result.code = code
  result.data = data

proc field*(node: JsonNode, key: string): JsonNode =
  ## Return a field or JSON null when absent.
  if node != nil and node.kind == JObject and node.hasKey(key): node[key]
  else: newJNull()

proc requireObject*(node: JsonNode) =
  ## Reject non-object method parameters.
  if node == nil or node.kind != JObject:
    raise rpcError(InvalidParams, "Expected an object")

proc requiredString*(node: JsonNode, key: string): string =
  ## Read a required string without silently defaulting malformed fields.
  let value = node.field(key)
  if value.kind != JString:
    raise rpcError(InvalidParams, "Expected string: " & key)
  value.getStr()

proc typedJson*[T](value: T): JsonNode =
  ## Encode a plain protocol record using jsony.
  parseJson(value.toJson())

proc decodeRecord*[T](node: JsonNode, recordType: typedesc[T]): T =
  ## Decode a plain protocol record using jsony.
  try:
    result = ($node).fromJson(T)
  except jsony.JsonError as error:
    raise rpcError(InvalidParams, error.msg)

proc addMeta(node: JsonNode, meta: JsonNode) =
  ## Attach metadata only when it was provided.
  if meta != nil and meta.kind != JNull:
    node["_meta"] = meta

proc textBlock*(text: string): ContentBlock =
  ## Construct a text content block.
  ContentBlock(kind: textContent, text: text)

proc resourceLink*(uri: string, name: string): ContentBlock =
  ## Construct a resource link content block.
  ContentBlock(kind: resourceLinkContent, uri: uri, name: name)

proc toJsonNode*(content: ContentBlock): JsonNode =
  ## Encode content, preserving raw fields received from another implementation.
  if content.raw != nil:
    return content.raw
  result = case content.kind
    of textContent: %*{"type": "text", "text": content.text}
    of resourceLinkContent: %*{"type": "resource_link", "uri": content.uri, "name": content.name}
    of imageContent: %*{"type": "image", "data": content.data, "mimeType": content.mimeType}
    of audioContent: %*{"type": "audio", "data": content.data, "mimeType": content.mimeType}
    of resourceContent: %*{"type": "resource", "resource": content.resource}
    of unknownContent: raise rpcError(InvalidParams, "Unknown content requires a raw payload")
  result.addMeta(content.meta)
  if content.annotations != nil:
    result["annotations"] = content.annotations

proc parseContent*(node: JsonNode): ContentBlock =
  ## Decode a content block while retaining unknown and optional fields.
  node.requireObject()
  result.raw = node
  result.meta = node.field("_meta")
  result.annotations = node.field("annotations")
  case node.requiredString("type")
  of "text":
    result.kind = textContent
    result.text = node.requiredString("text")
  of "resource_link":
    result.kind = resourceLinkContent
    result.uri = node.requiredString("uri")
    result.name = node.requiredString("name")
  of "image", "audio":
    result.kind = if node["type"].getStr() == "image": imageContent else: audioContent
    result.data = node.requiredString("data")
    result.mimeType = node.requiredString("mimeType")
  of "resource":
    result.kind = resourceContent
    result.resource = node.field("resource")
    result.resource.requireObject()
  else:
    result.kind = unknownContent

proc toJsonNode*(request: PromptRequest): JsonNode =
  ## Encode a prompt using ACP content discriminators.
  result = %*{"sessionId": request.sessionId, "prompt": newJArray()}
  for content in request.prompt:
    result["prompt"].add(content.toJsonNode())
  result.addMeta(request.meta)

proc parsePrompt*(node: JsonNode): PromptRequest =
  ## Validate and decode a prompt request.
  result.sessionId = node.requiredString("sessionId")
  result.meta = node.field("_meta")
  let blocks = node.field("prompt")
  if blocks.kind != JArray:
    raise rpcError(InvalidParams, "Expected prompt content array")
  for content in blocks:
    result.prompt.add(parseContent(content))

proc parseSessionRequest*(node: JsonNode, load = false): SessionRequest =
  ## Decode session setup without executing or interpreting MCP configuration.
  result.cwd = node.requiredString("cwd")
  result.meta = node.field("_meta")
  let servers = node.field("mcpServers")
  if servers.kind != JArray:
    raise rpcError(InvalidParams, "Expected mcpServers array")
  for server in servers:
    result.mcpServers.add(server)
  if load:
    result.sessionId = node.requiredString("sessionId")

proc toJsonNode*(request: SessionRequest, load = false): JsonNode =
  ## Encode new or load session parameters.
  result = %*{"cwd": request.cwd, "mcpServers": request.mcpServers}
  result.addMeta(request.meta)
  if load:
    result["sessionId"] = %request.sessionId

proc toJsonNode*(response: SessionResponse, load = false): JsonNode =
  ## Encode initial session state without inventing absent optional fields.
  result = newJObject()
  if not load:
    result["sessionId"] = %response.sessionId
  if response.modes != nil: result["modes"] = response.modes
  if response.configOptions != nil: result["configOptions"] = response.configOptions
  result.addMeta(response.meta)

proc parseSessionResponse*(node: JsonNode, sessionId = ""): SessionResponse =
  ## Decode a new session response or loaded session state.
  if node == nil or node.kind != JObject:
    raise newException(AcpProtocolError, "Expected a session response object")
  if sessionId.len == 0 and (node.field("sessionId").kind != JString or
      node["sessionId"].getStr().len == 0):
    raise newException(AcpProtocolError, "Expected a nonempty sessionId in session/new response")
  result.sessionId = if sessionId.len > 0: sessionId else: node["sessionId"].getStr()
  result.modes = node.field("modes")
  result.configOptions = node.field("configOptions")
  result.meta = node.field("_meta")

proc wireName*(reason: StopReason): string =
  ## Return the stable ACP stop reason spelling.
  case reason
  of endTurn: "end_turn"
  of maxTokens: "max_tokens"
  of maxTurnRequests: "max_turn_requests"
  of refused: "refusal"
  of cancelled: "cancelled"

proc toJsonNode*(response: PromptResponse): JsonNode =
  ## Encode the response that ends an ACP v1 prompt turn.
  result = %*{"stopReason": response.stopReason.wireName()}
  result.addMeta(response.meta)

proc parsePromptResponse*(node: JsonNode): PromptResponse =
  ## Decode a prompt completion and reject invalid stop reasons.
  if node.field("stopReason").kind != JString:
    raise newException(AcpProtocolError, "Missing prompt stop reason")
  case node["stopReason"].getStr()
  of "end_turn": result.stopReason = endTurn
  of "max_tokens": result.stopReason = maxTokens
  of "max_turn_requests": result.stopReason = maxTurnRequests
  of "refusal": result.stopReason = refused
  of "cancelled": result.stopReason = cancelled
  else: raise newException(AcpProtocolError, "Unknown prompt stop reason")
  result.meta = node.field("_meta")

proc parseToolContent*(node: JsonNode): ToolContent =
  ## Decode rich tool content, text diffs, and terminal references.
  node.requireObject()
  result.raw = node
  case node.requiredString("type")
  of "content":
    result.kind = blockToolContent
    result.content = parseContent(node.field("content"))
  of "diff":
    result.kind = diffToolContent
    result.diff.path = node.requiredString("path")
    result.diff.newText = node.requiredString("newText")
    let oldText = node.field("oldText")
    if oldText.kind == JString: result.diff.oldText = some(oldText.getStr())
    elif oldText.kind != JNull: raise rpcError(InvalidParams, "Expected oldText string or null")
  of "terminal":
    result.kind = terminalToolContent
    result.terminalId = node.requiredString("terminalId")
  else:
    result.kind = unknownToolContent

proc toJsonNode*(content: ToolContent): JsonNode =
  ## Encode rich tool content or retain an unfamiliar original variant.
  if content.raw != nil: return content.raw
  case content.kind
  of blockToolContent:
    result = %*{"type": "content", "content": content.content.toJsonNode()}
  of diffToolContent:
    result = %*{"type": "diff", "path": content.diff.path,
      "oldText": (if content.diff.oldText.isSome: %content.diff.oldText.get() else: newJNull()),
      "newText": content.diff.newText}
  of terminalToolContent:
    result = %*{"type": "terminal", "terminalId": content.terminalId}
  of unknownToolContent:
    raise rpcError(InvalidParams, "Unknown tool content requires a raw payload")

proc parseToolCall*(node: JsonNode): ToolCall =
  ## Decode tool reporting, retaining patch fields and rich content verbatim.
  node.requireObject()
  result = ToolCall(toolCallId: node.requiredString("toolCallId"),
    title: node.field("title").getStr(), name: node.field("name").getStr(),
    kind: node.field("kind").getStr(), status: node.field("status").getStr(),
    rawInput: node.field("rawInput"), rawOutput: node.field("rawOutput"),
    meta: node.field("_meta"), raw: node.copy())
  if result.raw.hasKey("sessionUpdate"): result.raw.delete("sessionUpdate")
  let
    content = node.field("content")
    locations = node.field("locations")
  if content.kind == JArray:
    var items: seq[ToolContent]
    for item in content: items.add(parseToolContent(item))
    result.content = some(items)
  elif content.kind != JNull: raise rpcError(InvalidParams, "Expected tool content array")
  if locations.kind == JArray:
    var items: seq[ToolLocation]
    for item in locations:
      discard item.requiredString("path")
      items.add(decodeRecord(item, ToolLocation))
    result.locations = some(items)
  elif locations.kind != JNull: raise rpcError(InvalidParams, "Expected tool locations array")

proc toJsonNode*(tool: ToolCall): JsonNode =
  ## Encode a tool report or update without filling in omitted patch fields.
  if tool.raw != nil: return tool.raw
  result = %*{"toolCallId": tool.toolCallId}
  for (key, value) in [("title", tool.title), ("name", tool.name),
      ("kind", tool.kind), ("status", tool.status)]:
    if value.len > 0: result[key] = %value
  if tool.content.isSome:
    result["content"] = newJArray()
    for content in tool.content.get(): result["content"].add(content.toJsonNode())
  if tool.locations.isSome: result["locations"] = typedJson(tool.locations.get())
  for (key, value) in [("rawInput", tool.rawInput), ("rawOutput", tool.rawOutput)]:
    if value != nil: result[key] = value
  result.addMeta(tool.meta)

proc parseUpdate*(params: JsonNode): SessionUpdate =
  ## Decode a session update while preserving unfamiliar variants verbatim.
  result.sessionId = params.requiredString("sessionId")
  result.outerMeta = params.field("_meta")
  let update = params.field("update")
  update.requireObject()
  result.raw = update
  result.meta = update.field("_meta")
  result.messageId = update.field("messageId").getStr()
  case update.requiredString("sessionUpdate")
  of "user_message_chunk", "agent_message_chunk", "agent_thought_chunk":
    result.kind = case update["sessionUpdate"].getStr()
      of "user_message_chunk": userMessageChunk
      of "agent_message_chunk": agentMessageChunk
      else: agentThoughtChunk
    result.content = parseContent(update.field("content"))
  of "tool_call", "tool_call_update":
    result.kind = if update["sessionUpdate"].getStr() == "tool_call": toolCall else: toolCallUpdate
    result.tool = parseToolCall(update)
  of "plan":
    result.kind = planUpdate
    let entries = update.field("entries")
    if entries.kind != JArray: raise rpcError(InvalidParams, "Expected plan entries")
    for entry in entries: result.entries.add(decodeRecord(entry, PlanEntry))
  else:
    result.kind = unknownUpdate

proc toJsonNode*(update: SessionUpdate): JsonNode =
  ## Encode a typed update or forward its original payload unchanged.
  var payload = update.raw
  if payload == nil:
    case update.kind
    of userMessageChunk, agentMessageChunk, agentThoughtChunk:
      let name = case update.kind
        of userMessageChunk: "user_message_chunk"
        of agentMessageChunk: "agent_message_chunk"
        else: "agent_thought_chunk"
      payload = %*{"sessionUpdate": name, "content": update.content.toJsonNode()}
      if update.messageId.len > 0: payload["messageId"] = %update.messageId
    of toolCall, toolCallUpdate:
      payload = update.tool.toJsonNode()
      payload["sessionUpdate"] = %(if update.kind == toolCall: "tool_call" else: "tool_call_update")
    of planUpdate:
      payload = %*{"sessionUpdate": "plan", "entries": typedJson(update.entries)}
    of unknownUpdate:
      raise rpcError(InvalidParams, "Unknown update requires a raw payload")
    payload.addMeta(update.meta)
  result = %*{"sessionId": update.sessionId, "update": payload}
  result.addMeta(update.outerMeta)

proc parsePermission*(node: JsonNode): PermissionRequest =
  ## Decode a permission request with its peer-supplied option identifiers.
  result.sessionId = node.requiredString("sessionId")
  result.toolCall = parseToolCall(node.field("toolCall"))
  let options = node.field("options")
  if options.kind != JArray: raise rpcError(InvalidParams, "Expected permission options")
  for option in options:
    discard option.requiredString("optionId")
    discard option.requiredString("name")
    discard option.requiredString("kind")
    result.options.add(PermissionOption(optionId: option["optionId"].getStr(),
      name: option["name"].getStr(), kind: option["kind"].getStr(),
      meta: option.field("_meta"), raw: option))
  result.meta = node.field("_meta")

proc toJsonNode*(request: PermissionRequest): JsonNode =
  ## Encode a permission request with structured tool details.
  result = %*{"sessionId": request.sessionId, "toolCall": request.toolCall.toJsonNode(),
    "options": newJArray()}
  for option in request.options:
    var node = option.raw
    if node == nil:
      node = %*{"optionId": option.optionId, "name": option.name, "kind": option.kind}
      node.addMeta(option.meta)
    result["options"].add(node)
  result.addMeta(request.meta)

proc toJsonNode*(outcome: PermissionOutcome): JsonNode =
  ## Encode the selected option or the protocol's cancelled outcome.
  result = %*{"outcome": {"outcome": outcome.outcome}}
  if outcome.outcome == "selected": result["outcome"]["optionId"] = %outcome.optionId

proc parsePermissionOutcome*(node: JsonNode): PermissionOutcome =
  ## Decode a permission response without treating rejection as an RPC failure.
  let outcome = node.field("outcome")
  if outcome.field("outcome").kind != JString:
    raise newException(AcpProtocolError, "Missing permission outcome")
  result.outcome = outcome["outcome"].getStr()
  case result.outcome
  of "selected":
    if outcome.field("optionId").kind != JString:
      raise newException(AcpProtocolError, "Missing permission optionId")
    result.optionId = outcome["optionId"].getStr()
  of "cancelled": discard
  else: raise newException(AcpProtocolError, "Unknown permission outcome")
