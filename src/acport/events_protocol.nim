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
  Notice* = object
    severity*, title*: string
    description*: Option[string]
    meta*, raw*: JsonNode
  CompactionUpdate* = object
    compactionId*, status*: string
    summaryPresent*, errorPresent*, metaPresent*: bool
    summary*: Option[seq[ContentBlock]]
    error*: Option[string]
    meta*, raw*: JsonNode
  CompactionSummaryChunk* = object
    compactionId*: string
    content*: ContentBlock
    meta*, raw*: JsonNode
  SessionCompaction* = object
    compactionId*, status*: string
    summary*: seq[ContentBlock]
    error*: Option[string]
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
    if optionalUnsigned(node, key).isNone: raise rpcError(InvalidParams, "Expected nonnegative integer: " & key)
  result = UsageUpdate(used: optionalUnsigned(node, "used").get(),
    size: optionalUnsigned(node, "size").get(), meta: node.field("_meta"), raw: node)
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

proc parseNotice*(node: JsonNode): Notice =
  ## Decode a transient notice without assuming a closed set of severities.
  result = Notice(severity: node.requiredString("severity"), title: node.requiredString("title"),
    meta: node.field("_meta"), raw: node)
  if result.title.len == 0: raise rpcError(InvalidParams, "Notice title must not be empty")
  let description = node.field("description")
  if description.kind == JString: result.description = some(description.getStr())
  elif description.kind != JNull: raise rpcError(InvalidParams, "Expected notice description string")

proc toJsonNode*(notice: Notice): JsonNode =
  ## Encode a live user-facing notice without adding it to conversation history.
  if notice.raw != nil: return notice.raw
  result = %*{"severity": notice.severity, "title": notice.title}
  if notice.description.isSome: result["description"] = %notice.description.get()
  result.attachMeta(notice.meta)

proc parseCompaction*(node: JsonNode): CompactionUpdate =
  ## Decode an ID-addressed compaction patch with explicit-null semantics.
  result = CompactionUpdate(compactionId: node.requiredString("compactionId"),
    status: node.requiredString("status"), summaryPresent: node.hasKey("summary"),
    errorPresent: node.hasKey("error"), metaPresent: node.hasKey("_meta"),
    meta: node.field("_meta"), raw: node)
  let summary = node.field("summary")
  if summary.kind != JNull:
    if summary.kind != JArray: raise rpcError(InvalidParams, "Expected compaction summary array")
    var blocks: seq[ContentBlock]
    for content in summary: blocks.add(parseContent(content))
    result.summary = some(blocks)
  let error = node.field("error")
  if error.kind == JString: result.error = some(error.getStr())
  elif error.kind != JNull: raise rpcError(InvalidParams, "Expected compaction error string")

proc toJsonNode*(update: CompactionUpdate): JsonNode =
  ## Encode a compaction patch without collapsing omission into clearing.
  if update.raw != nil: return update.raw
  result = %*{"compactionId": update.compactionId, "status": update.status}
  if update.summaryPresent:
    result["summary"] = newJNull()
    if update.summary.isSome:
      result["summary"] = newJArray()
      for content in update.summary.get(): result["summary"].add(content.toJsonNode())
  if update.errorPresent: result["error"] = if update.error.isSome: %update.error.get() else: newJNull()
  if update.metaPresent: result["_meta"] = if update.meta == nil: newJNull() else: update.meta

proc parseCompactionSummary*(node: JsonNode): CompactionSummaryChunk =
  ## Decode one ordered content chunk without treating chunk metadata as entity metadata.
  CompactionSummaryChunk(compactionId: node.requiredString("compactionId"),
    content: parseContent(node.field("content")), meta: node.field("_meta"), raw: node)

proc toJsonNode*(chunk: CompactionSummaryChunk): JsonNode =
  ## Encode one appended compaction-summary block.
  if chunk.raw != nil: return chunk.raw
  result = %*{"compactionId": chunk.compactionId, "content": chunk.content.toJsonNode()}
  result.attachMeta(chunk.meta)

proc parseNoticeUpdate*(update: SessionUpdate): Option[Notice] =
  ## Read notices through the source-compatible update representation.
  if update.raw.field("sessionUpdate").getStr() == "notice": result = some(parseNotice(update.raw))

proc parseCompactionUpdate*(update: SessionUpdate): Option[CompactionUpdate] =
  ## Read a typed compaction patch without expanding UpdateKind.
  if update.raw.field("sessionUpdate").getStr() == "compaction_update": result = some(parseCompaction(update.raw))

proc parseCompactionSummaryChunk*(update: SessionUpdate): Option[CompactionSummaryChunk] =
  ## Read an appended summary content block from a compatible raw update.
  if update.raw.field("sessionUpdate").getStr() == "compaction_summary_chunk":
    result = some(parseCompactionSummary(update.raw))

proc noticeUpdate*(sessionId: string, notice: Notice): SessionUpdate =
  ## Construct a notice to send only to peers that opted in.
  let node = notice.toJsonNode().copy()
  node["sessionUpdate"] = %"notice"
  SessionUpdate(sessionId: sessionId, kind: unknownUpdate, raw: node)

proc compactionUpdate*(sessionId: string, update: CompactionUpdate): SessionUpdate =
  ## Construct an ID-addressed compaction patch.
  let node = update.toJsonNode().copy()
  node["sessionUpdate"] = %"compaction_update"
  SessionUpdate(sessionId: sessionId, kind: unknownUpdate, raw: node)

proc compactionSummaryChunk*(sessionId: string, chunk: CompactionSummaryChunk): SessionUpdate =
  ## Construct one ordered compaction-summary append.
  let node = chunk.toJsonNode().copy()
  node["sessionUpdate"] = %"compaction_summary_chunk"
  SessionUpdate(sessionId: sessionId, kind: unknownUpdate, raw: node)

proc applyCompaction*(compactions: JsonNode, update: JsonNode) =
  ## Upsert or append a validated compaction while preserving first-seen position.
  let
    chunk = update.field("sessionUpdate").getStr() == "compaction_summary_chunk"
    id = update.requiredString("compactionId")
  if chunk: discard parseCompactionSummary(update)
  else: discard parseCompaction(update)
  var entity: JsonNode
  for item in compactions:
    if item.field("compactionId").getStr() == id: entity = item
  if entity == nil:
    entity = %*{"compactionId": id, "status": "in_progress", "summary": []}
    compactions.add(entity)
  if chunk:
    if entity.field("summary").kind != JArray: entity["summary"] = newJArray()
    entity["summary"].add(update["content"])
  else:
    entity["status"] = update["status"]
    for key in ["summary", "error", "_meta"]:
      if update.hasKey(key): entity[key] = update[key]

proc parseSessionCompaction*(node: JsonNode): SessionCompaction =
  ## Decode an owned assembled compaction snapshot.
  let patch = parseCompaction(node)
  result = SessionCompaction(compactionId: patch.compactionId, status: patch.status,
    error: patch.error, meta: patch.meta, raw: node)
  if patch.summary.isSome: result.summary = patch.summary.get()
