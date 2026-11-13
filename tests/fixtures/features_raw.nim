import std/[json, os]

proc send(node: JsonNode) =
  ## Write an independent JSON-RPC wire message.
  stdout.writeLine($node)
  stdout.flushFile()

proc receive(): JsonNode =
  ## Read a complete client message using only the standard library.
  parseJson(stdin.readLine())

proc main() =
  ## Finish URL flows before consent and send duplicate/unknown completions.
  let init = receive()
  let unsupported = paramCount() > 0 and paramStr(1) == "unsupported"
  if not unsupported:
    doAssert init["params"]["clientCapabilities"]["elicitation"] == %*{"form":{}, "url":{}}
  send(%*{"jsonrpc":"2.0", "id":init["id"], "result":{"protocolVersion":1, "agentCapabilities":{}}})
  let setup = receive()
  send(%*{"jsonrpc":"2.0", "id":setup["id"], "result":{"sessionId":"raw-features"}})
  let prompt = receive()
  if unsupported:
    send(%*{"jsonrpc":"2.0", "id":"unsupported", "method":"elicitation/create", "params":{
      "mode":"form", "sessionId":"raw-features", "message":"Not advertised", "requestedSchema":{}}})
    let rejected = receive()
    doAssert rejected["error"]["code"].getInt() == -32602
    send(%*{"jsonrpc":"2.0", "id":prompt["id"], "result":{"stopReason":"end_turn"}})
    while not stdin.endOfFile(): discard receive()
    return
  send(%*{"jsonrpc":"2.0", "id":"url-request", "method":"elicitation/create", "params":{
    "mode":"url", "sessionId":"raw-features", "message":"Consent", "url":"https://example.invalid/never-fetch",
    "elicitationId":"early", "_meta":{"source":"raw"}}})
  send(%*{"jsonrpc":"2.0", "id":"duplicate", "method":"elicitation/create", "params":{
    "mode":"url", "sessionId":"raw-features", "message":"Duplicate", "url":"https://example.invalid/never-fetch",
    "elicitationId":"early"}})
  for id in ["unknown", "early", "early"]:
    send(%*{"jsonrpc":"2.0", "method":"elicitation/complete", "params":{"elicitationId":id}})
  send(%*{"jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":"raw-features",
    "update":{"sessionUpdate":"agent_message_chunk", "content":{"type":"text", "text":"received"}}}})
  let duplicate = receive()
  doAssert duplicate["id"].getStr() == "duplicate"
  doAssert duplicate["error"]["code"].getInt() == -32602
  let consent = receive()
  doAssert consent["id"].getStr() == "url-request"
  for id in ["early", "unknown"]:
    send(%*{"jsonrpc":"2.0", "method":"elicitation/complete", "params":{"elicitationId":id}})
  send(%*{"jsonrpc":"2.0", "id":prompt["id"], "result":{"stopReason":"end_turn"}})
  while not stdin.endOfFile(): discard receive()

main()
