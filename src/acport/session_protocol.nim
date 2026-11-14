import
  std/[json, options],
  ./protocol

type
  ConfigValueKind* = enum
    stringConfigValue, booleanConfigValue
  ConfigValue* = object
    case kind*: ConfigValueKind
    of stringConfigValue: stringValue*: string
    of booleanConfigValue: boolValue*: bool

  ConfigOptionKind* = enum
    selectConfigOption, booleanConfigOption, unknownConfigOption
  ConfigChoice* = object
    value*, name*: string
    description*: Option[string]
    meta*, raw*: JsonNode
  ConfigGroup* = object
    group*, name*: string
    options*: seq[ConfigChoice]
    meta*, raw*: JsonNode
  SessionConfigOption* = object
    id*, name*: string
    description*, category*: Option[string]
    kind*: ConfigOptionKind
    currentValue*: ConfigValue
    options*: seq[ConfigChoice]
    groups*: seq[ConfigGroup]
    meta*, raw*: JsonNode

  SessionMode* = object
    id*, name*: string
    description*: Option[string]
    meta*, raw*: JsonNode
  SessionModeState* = object
    currentModeId*: string
    availableModes*: seq[SessionMode]
    meta*, raw*: JsonNode

  SessionInfo* = object
    sessionId*, cwd*: string
    additionalDirectories*: seq[string]
    title*, updatedAt*: Option[string]
    meta*, raw*: JsonNode
  ListSessionsRequest* = object
    cwd*, cursor*: Option[string]
    meta*: JsonNode
  ListSessionsResponse* = object
    sessions*: seq[SessionInfo]
    nextCursor*: Option[string]
    meta*: JsonNode
  SetConfigOptionRequest* = object
    sessionId*, configId*: string
    value*: ConfigValue
    meta*: JsonNode
  SetModeRequest* = object
    sessionId*, modeId*: string
    meta*: JsonNode
  CloseSessionRequest* = object
    sessionId*: string
    meta*: JsonNode
  DeleteSessionRequest* = object
    sessionId*: string
    meta*, raw*: JsonNode
  DeleteSessionResponse* = EmptyMessage
  SessionInfoUpdate* = object
    titlePresent*, updatedAtPresent*: bool
    title*, updatedAt*: Option[string]
    meta*, raw*: JsonNode

proc configValue*(value: string): ConfigValue =
  ## Construct a select-option identifier.
  ConfigValue(kind: stringConfigValue, stringValue: value)

proc configValue*(value: bool): ConfigValue =
  ## Construct a boolean configuration value.
  ConfigValue(kind: booleanConfigValue, boolValue: value)

proc optionalString(node: JsonNode, key: string): Option[string] =
  ## Preserve absent or null optional strings without accepting wrong types.
  let value = node.field(key)
  if value.kind == JString: result = some(value.getStr())
  elif value.kind != JNull: raise rpcError(InvalidParams, "Expected optional string: " & key)

proc addMeta(node: JsonNode, meta: JsonNode) =
  ## Attach supplied metadata without adding absent fields.
  if meta != nil and meta.kind != JNull: node["_meta"] = meta

proc addOptional(node: JsonNode, key: string, value: Option[string]) =
  ## Write a present optional string.
  if value.isSome: node[key] = %value.get()

proc parseConfigChoice(node: JsonNode): ConfigChoice =
  ## Decode a select choice and retain extension metadata.
  ConfigChoice(value: node.requiredString("value"), name: node.requiredString("name"),
    description: optionalString(node, "description"), meta: node.field("_meta"), raw: node)

proc toJsonNode*(choice: ConfigChoice): JsonNode =
  ## Encode a select choice or forward its original representation.
  if choice.raw != nil: return choice.raw
  result = %*{"value": choice.value, "name": choice.name}
  result.addOptional("description", choice.description)
  result.addMeta(choice.meta)

proc parseConfigOption*(node: JsonNode): SessionConfigOption =
  ## Decode flat/grouped selects, negotiated booleans, or an unfamiliar option type.
  result.id = node.requiredString("id")
  result.name = node.requiredString("name")
  result.description = optionalString(node, "description")
  result.category = optionalString(node, "category")
  result.meta = node.field("_meta")
  result.raw = node
  case node.requiredString("type")
  of "select":
    result.kind = selectConfigOption
    result.currentValue = configValue(node.requiredString("currentValue"))
    let choices = node.field("options")
    if choices.kind != JArray: raise rpcError(InvalidParams, "Expected select options array")
    var grouped = false
    for index in 0 ..< choices.len:
      let choice = choices[index]
      choice.requireObject()
      if index == 0: grouped = choice.hasKey("group")
      if choice.hasKey("group") != grouped:
        raise rpcError(InvalidParams, "Cannot mix select choices and groups")
      if grouped:
        var group = ConfigGroup(group: choice.requiredString("group"),
          name: choice.requiredString("name"), meta: choice.field("_meta"), raw: choice)
        let items = choice.field("options")
        if items.kind != JArray: raise rpcError(InvalidParams, "Expected group options array")
        for item in items: group.options.add(parseConfigChoice(item))
        result.groups.add(group)
      else:
        result.options.add(parseConfigChoice(choice))
  of "boolean":
    result.kind = booleanConfigOption
    let value = node.field("currentValue")
    if value.kind != JBool: raise rpcError(InvalidParams, "Expected boolean currentValue")
    result.currentValue = configValue(value.getBool())
  else:
    result.kind = unknownConfigOption

proc parseConfigOptions*(node: JsonNode): seq[SessionConfigOption] =
  ## Decode a complete ordered configuration catalog.
  if node.kind != JArray: raise rpcError(InvalidParams, "Expected configOptions array")
  for option in node: result.add(parseConfigOption(option))

proc toJsonNode*(option: SessionConfigOption): JsonNode =
  ## Encode a configuration option, preserving raw payloads when supplied.
  if option.raw != nil: return option.raw
  result = %*{"id": option.id, "name": option.name}
  result.addOptional("description", option.description)
  result.addOptional("category", option.category)
  result.addMeta(option.meta)
  case option.kind
  of selectConfigOption:
    if option.currentValue.kind != stringConfigValue:
      raise rpcError(InvalidParams, "Select values must be strings")
    if option.groups.len > 0 and option.options.len > 0:
      raise rpcError(InvalidParams, "Cannot mix select choices and groups")
    result["type"] = %"select"
    result["currentValue"] = %option.currentValue.stringValue
    result["options"] = newJArray()
    for choice in option.options: result["options"].add(choice.toJsonNode())
    for group in option.groups:
      var node = group.raw
      if node == nil:
        node = %*{"group": group.group, "name": group.name, "options": newJArray()}
        for choice in group.options: node["options"].add(choice.toJsonNode())
        node.addMeta(group.meta)
      result["options"].add(node)
  of booleanConfigOption:
    if option.currentValue.kind != booleanConfigValue:
      raise rpcError(InvalidParams, "Boolean values must be booleans")
    result["type"] = %"boolean"
    result["currentValue"] = %option.currentValue.boolValue
  of unknownConfigOption:
    raise rpcError(InvalidParams, "Unknown option requires a raw payload")

proc toJsonNode*(options: seq[SessionConfigOption]): JsonNode =
  ## Encode a complete ordered configuration catalog.
  result = newJArray()
  for option in options: result.add(option.toJsonNode())

proc parseSetConfigOption*(node: JsonNode): SetConfigOptionRequest =
  ## Decode the stable v1 select/boolean setter request union.
  result.sessionId = node.requiredString("sessionId")
  result.configId = node.requiredString("configId")
  result.meta = node.field("_meta")
  let kind = if node.hasKey("type"): node.requiredString("type") else: "id"
  if kind == "boolean":
    if node.field("value").kind != JBool: raise rpcError(InvalidParams, "Expected boolean value")
    result.value = configValue(node["value"].getBool())
  elif kind == "id":
    result.value = configValue(node.requiredString("value"))
  else:
    raise rpcError(InvalidParams, "Unsupported config value type")

proc toJsonNode*(request: SetConfigOptionRequest): JsonNode =
  ## Encode a configuration change with boolean discrimination when required.
  result = %*{"sessionId": request.sessionId, "configId": request.configId}
  case request.value.kind
  of stringConfigValue: result["value"] = %request.value.stringValue
  of booleanConfigValue:
    result["type"] = %"boolean"
    result["value"] = %request.value.boolValue
  result.addMeta(request.meta)

proc validateConfigValue*(options: seq[SessionConfigOption], id: string, value: ConfigValue) =
  ## Reject unknown settings, wrong value types, and unadvertised choices.
  for option in options:
    if option.id != id: continue
    case option.kind
    of booleanConfigOption:
      if value.kind == booleanConfigValue: return
    of selectConfigOption:
      if value.kind == stringConfigValue:
        for choice in option.options:
          if choice.value == value.stringValue: return
        for group in option.groups:
          for choice in group.options:
            if choice.value == value.stringValue: return
    of unknownConfigOption: discard
    raise rpcError(InvalidParams, "Unsupported value for config option: " & id)
  raise rpcError(InvalidParams, "Unknown config option: " & id)

proc parseModes*(node: JsonNode): SessionModeState =
  ## Decode current and available legacy modes.
  result.currentModeId = node.requiredString("currentModeId")
  result.meta = node.field("_meta")
  result.raw = node
  let modes = node.field("availableModes")
  if modes.kind != JArray: raise rpcError(InvalidParams, "Expected availableModes array")
  for mode in modes:
    result.availableModes.add(SessionMode(id: mode.requiredString("id"),
      name: mode.requiredString("name"), description: optionalString(mode, "description"),
      meta: mode.field("_meta"), raw: mode))

proc toJsonNode*(modes: SessionModeState): JsonNode =
  ## Encode mode state or retain the original payload.
  if modes.raw != nil: return modes.raw
  result = %*{"currentModeId": modes.currentModeId, "availableModes": newJArray()}
  for mode in modes.availableModes:
    var node = mode.raw
    if node == nil:
      node = %*{"id": mode.id, "name": mode.name}
      node.addOptional("description", mode.description)
      node.addMeta(mode.meta)
    result["availableModes"].add(node)
  result.addMeta(modes.meta)

proc parseSessionInfo*(node: JsonNode): SessionInfo =
  ## Decode a stored session descriptor without activating that session.
  SessionInfo(sessionId: node.requiredString("sessionId"), cwd: node.requiredString("cwd"),
    additionalDirectories: parseDirectories(node.field("additionalDirectories")),
    title: optionalString(node, "title"), updatedAt: optionalString(node, "updatedAt"),
    meta: node.field("_meta"), raw: node)

proc toJsonNode*(info: SessionInfo): JsonNode =
  ## Encode a session descriptor with optional title and timestamp.
  if info.raw != nil: return info.raw
  result = %*{"sessionId": info.sessionId, "cwd": info.cwd}
  if info.additionalDirectories.len > 0: result["additionalDirectories"] = %info.additionalDirectories
  result.addOptional("title", info.title)
  result.addOptional("updatedAt", info.updatedAt)
  result.addMeta(info.meta)

proc parseListSessionsRequest*(node: JsonNode): ListSessionsRequest =
  ## Decode optional listing filters and an opaque cursor.
  node.requireObject()
  ListSessionsRequest(cwd: optionalString(node, "cwd"), cursor: optionalString(node, "cursor"),
    meta: node.field("_meta"))

proc toJsonNode*(request: ListSessionsRequest): JsonNode =
  ## Encode only the supplied session-list filters.
  result = newJObject()
  result.addOptional("cwd", request.cwd)
  result.addOptional("cursor", request.cursor)
  result.addMeta(request.meta)

proc parseListSessionsResponse*(node: JsonNode): ListSessionsResponse =
  ## Decode one page of session history and its optional next cursor.
  let sessions = node.field("sessions")
  if sessions.kind != JArray: raise rpcError(InvalidParams, "Expected sessions array")
  for session in sessions: result.sessions.add(parseSessionInfo(session))
  result.nextCursor = optionalString(node, "nextCursor")
  result.meta = node.field("_meta")

proc toJsonNode*(response: ListSessionsResponse): JsonNode =
  ## Encode one session-history page without interpreting cursor contents.
  result = %*{"sessions": newJArray()}
  for info in response.sessions: result["sessions"].add(info.toJsonNode())
  result.addOptional("nextCursor", response.nextCursor)
  result.addMeta(response.meta)

proc parseSetMode*(node: JsonNode): SetModeRequest =
  ## Decode a legacy mode change.
  SetModeRequest(sessionId: node.requiredString("sessionId"),
    modeId: node.requiredString("modeId"), meta: node.field("_meta"))

proc parseCloseSession*(node: JsonNode): CloseSessionRequest =
  ## Decode a close request without confusing it with history deletion.
  CloseSessionRequest(sessionId: node.requiredString("sessionId"), meta: node.field("_meta"))

proc parseDeleteSessionRequest*(node: JsonNode): DeleteSessionRequest =
  ## Decode history deletion independently of active-session closure.
  DeleteSessionRequest(sessionId: node.requiredString("sessionId"), meta: node.field("_meta"), raw: node)

proc toJsonNode*(request: DeleteSessionRequest): JsonNode =
  ## Encode deletion of a stored session identifier.
  if request.raw != nil: return request.raw
  result = %*{"sessionId": request.sessionId}
  result.addMeta(request.meta)

proc parseConfigOptionUpdate*(update: SessionUpdate): Option[seq[SessionConfigOption]] =
  ## Decode configuration updates while keeping the 1.0 UpdateKind enum unchanged.
  if update.raw.field("sessionUpdate").getStr() == "config_option_update":
    result = some(parseConfigOptions(update.raw.field("configOptions")))

proc parseCurrentModeUpdate*(update: SessionUpdate): Option[string] =
  ## Decode a legacy current-mode update without adding enum variants.
  if update.raw.field("sessionUpdate").getStr() == "current_mode_update":
    result = some(update.raw.requiredString("currentModeId"))

proc parseSessionInfoUpdate*(update: SessionUpdate): Option[SessionInfoUpdate] =
  ## Preserve the difference between omitted metadata and an explicit null clear.
  if update.raw.field("sessionUpdate").getStr() != "session_info_update": return
  result = some(SessionInfoUpdate(titlePresent: update.raw.hasKey("title"),
    updatedAtPresent: update.raw.hasKey("updatedAt"), title: optionalString(update.raw, "title"),
    updatedAt: optionalString(update.raw, "updatedAt"), meta: update.raw.field("_meta"), raw: update.raw))

proc configOptionUpdate*(sessionId: string, options: seq[SessionConfigOption]): SessionUpdate =
  ## Construct a configuration update using the compatible raw-update representation.
  SessionUpdate(sessionId: sessionId, kind: unknownUpdate,
    raw: %*{"sessionUpdate": "config_option_update", "configOptions": options.toJsonNode()})

proc currentModeUpdate*(sessionId: string, modeId: string): SessionUpdate =
  ## Construct a legacy mode update.
  SessionUpdate(sessionId: sessionId, kind: unknownUpdate,
    raw: %*{"sessionUpdate": "current_mode_update", "currentModeId": modeId})

proc sessionInfoUpdate*(sessionId: string, info: SessionInfoUpdate): SessionUpdate =
  ## Construct a session metadata patch with explicit-null support.
  var node = info.raw
  if node == nil:
    node = %*{"sessionUpdate": "session_info_update"}
    if info.titlePresent: node["title"] = if info.title.isSome: %info.title.get() else: newJNull()
    if info.updatedAtPresent: node["updatedAt"] = if info.updatedAt.isSome: %info.updatedAt.get() else: newJNull()
    node.addMeta(info.meta)
  SessionUpdate(sessionId: sessionId, kind: unknownUpdate, raw: node)
