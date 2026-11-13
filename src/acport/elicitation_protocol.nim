import
  std/[json, options],
  ./protocol

type
  ElicitationMode* = enum formElicitation, urlElicitation, unknownElicitationMode
  ElicitationScope* = enum sessionElicitationScope, requestElicitationScope
  ElicitationAction* = enum acceptElicitation, declineElicitation, cancelElicitation, unknownElicitationAction
  ElicitationRequest* = object
    mode*: ElicitationMode
    scope*: ElicitationScope
    message*, sessionId*: string
    toolCallId*: Option[string]
    requestId*: JsonNode
    requestedSchema*: JsonNode
    elicitationId*, url*: string
    meta*, raw*: JsonNode
  ElicitationResponse* = object
    action*: ElicitationAction
    content*, meta*, raw*: JsonNode
  ElicitationComplete* = object
    elicitationId*: string
    meta*, raw*: JsonNode

proc attachMeta(node: JsonNode, meta: JsonNode) =
  ## Preserve provided metadata without supplying defaults.
  if meta != nil and meta.kind != JNull: node["_meta"] = meta

proc parseElicitationRequest*(node: JsonNode): ElicitationRequest =
  ## Decode ACP's explicit modes and flattened scopes, leaving schemas opaque.
  node.requireObject()
  result.message = node.requiredString("message")
  result.meta = node.field("_meta")
  result.raw = node
  if node.hasKey("sessionId") == node.hasKey("requestId"):
    raise rpcError(InvalidParams, "Elicitation needs exactly one sessionId or requestId")
  if node.hasKey("sessionId"):
    result.scope = sessionElicitationScope
    result.sessionId = node.requiredString("sessionId")
    let tool = node.field("toolCallId")
    if tool.kind == JString: result.toolCallId = some(tool.getStr())
    elif tool.kind != JNull: raise rpcError(InvalidParams, "Expected optional toolCallId string")
  else:
    result.scope = requestElicitationScope
    result.requestId = node["requestId"]
    if result.requestId.kind notin {JString, JInt, JNull}:
      raise rpcError(InvalidParams, "Invalid elicitation requestId")
    if node.field("toolCallId").kind != JNull:
      raise rpcError(InvalidParams, "toolCallId requires a session scope")
  case node.requiredString("mode")
  of "form":
    result.mode = formElicitation
    result.requestedSchema = node.field("requestedSchema")
    result.requestedSchema.requireObject()
  of "url":
    result.mode = urlElicitation
    result.elicitationId = node.requiredString("elicitationId")
    result.url = node.requiredString("url")
  else: result.mode = unknownElicitationMode

proc toJsonNode*(request: ElicitationRequest): JsonNode =
  ## Encode an envelope without rendering forms or interpreting URLs.
  if request.raw != nil: return request.raw
  result = %*{"message":request.message}
  case request.scope
  of sessionElicitationScope:
    result["sessionId"] = %request.sessionId
    if request.toolCallId.isSome: result["toolCallId"] = %request.toolCallId.get()
  of requestElicitationScope:
    result["requestId"] = if request.requestId == nil: newJNull() else: request.requestId
  case request.mode
  of formElicitation:
    result["mode"] = %"form"
    result["requestedSchema"] = if request.requestedSchema == nil: newJNull() else: request.requestedSchema
  of urlElicitation:
    result["mode"] = %"url"
    result["elicitationId"] = %request.elicitationId
    result["url"] = %request.url
  of unknownElicitationMode: raise rpcError(InvalidParams, "Unknown elicitation mode requires raw JSON")
  result.attachMeta(request.meta)

proc validateContent(node: JsonNode) =
  ## Validate ACP response value shapes, without validating the requested schema.
  if node == nil or node.kind == JNull: return
  node.requireObject()
  for key, value in node:
    case value.kind
    of JString, JInt, JFloat, JBool: discard
    of JArray:
      for item in value:
        if item.kind != JString: raise rpcError(InvalidParams, "Expected string array: " & key)
    else: raise rpcError(InvalidParams, "Unsupported elicitation content value: " & key)

proc parseElicitationResponse*(node: JsonNode): ElicitationResponse =
  ## Preserve unfamiliar actions without treating them as acceptance.
  result.meta = node.field("_meta")
  result.raw = node
  case node.requiredString("action")
  of "accept":
    result.action = acceptElicitation
    result.content = node.field("content")
    validateContent(result.content)
  of "decline": result.action = declineElicitation
  of "cancel": result.action = cancelElicitation
  else: result.action = unknownElicitationAction

proc toJsonNode*(response: ElicitationResponse): JsonNode =
  ## Encode decisions while keeping content meaningful only for acceptance.
  if response.raw != nil: return response.raw
  result = newJObject()
  case response.action
  of acceptElicitation:
    result["action"] = %"accept"
    validateContent(response.content)
    if response.content != nil and response.content.kind != JNull: result["content"] = response.content
  of declineElicitation: result["action"] = %"decline"
  of cancelElicitation: result["action"] = %"cancel"
  of unknownElicitationAction: raise rpcError(InvalidParams, "Unknown elicitation action requires raw JSON")
  result.attachMeta(response.meta)

proc parseElicitationComplete*(node: JsonNode): ElicitationComplete =
  ## Decode an opaque URL-flow identifier and optional metadata.
  ElicitationComplete(elicitationId: node.requiredString("elicitationId"),
    meta: node.field("_meta"), raw: node)

proc toJsonNode*(completion: ElicitationComplete): JsonNode =
  ## Encode an external-flow completion without adding a result or credentials.
  if completion.raw != nil: return completion.raw
  result = %*{"elicitationId":completion.elicitationId}
  result.attachMeta(completion.meta)
