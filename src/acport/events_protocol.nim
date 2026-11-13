import
  std/[json, options],
  ./protocol

type
  AvailableCommandInput* = object
    hint*: string
    meta*, raw*: JsonNode
  AvailableCommand* = object
    name*, description*: string
    input*: Option[AvailableCommandInput]
    meta*, raw*: JsonNode
  UsageCost* = object
    amount*: float64
    currency*: string
    meta*, raw*: JsonNode
  UsageUpdate* = object
    used*, size*: uint64
    cost*: Option[UsageCost]
    meta*, raw*: JsonNode

proc attachMeta(node: JsonNode, meta: JsonNode) =
  ## Preserve optional metadata without inventing a value.
  if meta != nil and meta.kind != JNull: node["_meta"] = meta

proc parseAvailableCommands*(node: JsonNode): seq[AvailableCommand] =
  ## Decode an ordered command catalog including optional input hints.
  if node == nil or node.kind != JArray: raise rpcError(InvalidParams, "Expected availableCommands array")
  for item in node:
    var command = AvailableCommand(name: item.requiredString("name"),
      description: item.requiredString("description"), meta: item.field("_meta"), raw: item)
    let input = item.field("input")
    if input.kind != JNull:
      command.input = some(AvailableCommandInput(hint: input.requiredString("hint"),
        meta: input.field("_meta"), raw: input))
    result.add(command)

proc toJsonNode*(commands: seq[AvailableCommand]): JsonNode =
  ## Encode constructed commands or forward their original payloads.
  result = newJArray()
  for command in commands:
    var node = command.raw
    if node == nil:
      node = %*{"name":command.name, "description":command.description}
      node.attachMeta(command.meta)
      if command.input.isSome:
        let input = command.input.get()
        var value = input.raw
        if value == nil:
          value = %*{"hint":input.hint}
          value.attachMeta(input.meta)
        node["input"] = value
    result.add(node)

proc parseUsage*(node: JsonNode): UsageUpdate =
  ## Decode nonnegative context counts and optional cumulative cost.
  for key in ["used", "size"]:
    let value = node.field(key)
    if value.kind != JInt or value.getBiggestInt() < 0:
      raise rpcError(InvalidParams, "Expected nonnegative integer: " & key)
  result = UsageUpdate(used: uint64(node["used"].getBiggestInt()),
    size: uint64(node["size"].getBiggestInt()), meta: node.field("_meta"), raw: node)
  let cost = node.field("cost")
  if cost.kind != JNull:
    if cost.field("amount").kind notin {JInt, JFloat}:
      raise rpcError(InvalidParams, "Expected numeric cost amount")
    result.cost = some(UsageCost(amount: cost["amount"].getFloat(),
      currency: cost.requiredString("currency"), meta: cost.field("_meta"), raw: cost))

proc toJsonNode*(usage: UsageUpdate): JsonNode =
  ## Encode an absolute usage report, preserving received extensions.
  if usage.raw != nil: return usage.raw
  result = %*{"used":usage.used, "size":usage.size}
  result.attachMeta(usage.meta)
  if usage.cost.isSome:
    let cost = usage.cost.get()
    var node = cost.raw
    if node == nil:
      node = %*{"amount":cost.amount, "currency":cost.currency}
      node.attachMeta(cost.meta)
    result["cost"] = node

proc parseAvailableCommandsUpdate*(update: SessionUpdate): Option[seq[AvailableCommand]] =
  ## Read command updates without expanding the source-compatible UpdateKind enum.
  if update.raw.field("sessionUpdate").getStr() == "available_commands_update":
    result = some(parseAvailableCommands(update.raw.field("availableCommands")))

proc parseUsageUpdate*(update: SessionUpdate): Option[UsageUpdate] =
  ## Read a typed usage report from the compatible raw update representation.
  if update.raw.field("sessionUpdate").getStr() == "usage_update": result = some(parseUsage(update.raw))

proc availableCommandsUpdate*(sessionId: string, commands: seq[AvailableCommand]): SessionUpdate =
  ## Construct a complete replacement command catalog.
  SessionUpdate(sessionId: sessionId, kind: unknownUpdate,
    raw: %*{"sessionUpdate":"available_commands_update", "availableCommands":commands.toJsonNode()})

proc usageUpdate*(sessionId: string, usage: UsageUpdate): SessionUpdate =
  ## Construct a usage notification without accumulating previously reported counts.
  let node = usage.toJsonNode().copy()
  node["sessionUpdate"] = %"usage_update"
  SessionUpdate(sessionId: sessionId, kind: unknownUpdate, raw: node)
