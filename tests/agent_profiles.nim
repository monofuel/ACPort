import
  std/[json, os, strtabs],
  acport

type
  TestAgent* = enum codex, grok, claude
  AgentCommand* = object
    command*: string
    args*: seq[string]
    environment*: StringTableRef

const
  CodexAdapterVersion* = "2.6.0"
  ClaudeAdapterVersion* = "0.106.0"

proc parseTestAgent*(name: string): TestAgent =
  ## Resolve only explicitly supported integration profiles.
  case name
  of "codex": codex
  of "grok": grok
  of "claude": claude
  else: raise newException(ValueError, "Unknown integration agent: " & name)

proc agentCommand*(agent: TestAgent): AgentCommand =
  ## Launch real ACP peers with test-local settings and existing credentials.
  result.environment = newStringTable("NO_BROWSER", "1", modeCaseSensitive)
  case agent
  of codex:
    result.command = absolutePath(getEnv("ACPORT_CODEX_ACP",
      "build/integration-tools/node_modules/.bin/codex-acp"))
    result.environment["CODEX_PATH"] = findExe("codex")
    result.environment["INITIAL_AGENT_MODE"] = "read-only"
    var config = %*{"approval_policy":"on-request", "sandbox_mode":"read-only", "mcp_servers":{}}
    let model = getEnv("ACPORT_TEST_MODEL")
    if model.len > 0: config["model"] = %model
    result.environment["CODEX_CONFIG"] = $config
  of grok:
    result.command = getEnv("ACPORT_GROK", findExe("grok"))
    result.args = @["--no-auto-update", "agent", "--no-leader"]
    let model = getEnv("ACPORT_GROK_MODEL")
    if model.len > 0: result.args.add(@["--model", model])
    result.args.add("stdio")
  of claude:
    result.command = absolutePath(getEnv("ACPORT_CLAUDE_ACP",
      "build/integration-tools/node_modules/.bin/claude-agent-acp"))
    result.environment["CLAUDE_AGENT_ACP_PROTOCOL"] = "v1"
    result.environment["CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION"] = "false"

proc sessionMeta*(agent: TestAgent): JsonNode =
  ## Select test-local permissions/settings without changing global files or models.
  if agent == grok:
    result = %*{"yoloMode":false, "autoMode":false}
  if agent == claude:
    result = %*{"claudeCode":{"options":{"settingSources":[], "mcpServers":{}}}}
    let model = getEnv("ACPORT_CLAUDE_MODEL")
    if model.len > 0: result["claudeCode"]["options"]["model"] = %model

proc authenticateAgent*(agent: TestAgent, client: AcpClient, info: InitializeResponse) =
  ## Authenticate Grok non-interactively using only advertised existing credentials.
  if agent != grok: return
  var cached, apiKey: bool
  for auth in info.authMethods:
    case auth.field("id").getStr()
    of "cached_token": cached = true
    of "xai.api_key": apiKey = true
    else: discard
  let methodId = if apiKey and getEnv("XAI_API_KEY").len > 0: "xai.api_key"
    elif cached: "cached_token"
    else: raise newException(ValueError, "Grok needs an existing login or XAI_API_KEY; interactive login is disabled")
  client.authenticate(methodId, 60_000, meta = %*{"headless":true})
