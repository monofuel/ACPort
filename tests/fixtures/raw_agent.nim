import
  std/[json, os, strutils]

proc send(node: JsonNode, fragmented = false) =
  ## Emit independent wire messages, optionally splitting UTF-8 across writes.
  let message = $node & "\n"
  if fragmented:
    for character in message:
      stdout.write(character)
      stdout.flushFile()
  else:
    stdout.write(message)
    stdout.flushFile()

proc receive(): JsonNode =
  ## Read the library's independently validated wire output.
  parseJson(stdin.readLine())

proc main() =
  ## Act as a raw JSON-RPC peer without importing ACPort or jsony.
  let initialization = receive()
  let sessionTests = paramCount() > 0 and paramStr(1) == "sessions"
  let authTests = paramCount() > 0 and paramStr(1) == "auth-meta"
  doAssert initialization["jsonrpc"].getStr() == "2.0"
  doAssert initialization["method"].getStr() == "initialize"
  doAssert initialization["params"]["clientCapabilities"] ==
    %*{"session": {"configOptions": {"boolean": {}}}}
  send(%*{"jsonrpc": "2.0", "id": initialization["id"], "result": {
    "protocolVersion": (if paramCount() > 0 and paramStr(1) == "version-mismatch": 2 else: 1),
    "agentCapabilities": (if sessionTests: %*{"sessionCapabilities":{"close":{}, "list":{}}} else: newJObject()),
    "authMethods": (if authTests: %*[{"id":"headless", "name":"Headless"}] else: newJArray())}})
  var lateConfig: JsonNode
  proc catalog(value: string): JsonNode =
    ## Build a catalog independently of ACPort's codecs.
    %*[{"id":"x", "name":"X", "type":"select", "currentValue":value,
      "options":[{"value":"a", "name":"A"}, {"value":"b", "name":"B"},
        {"value":"c", "name":"C"}]}]
  while not stdin.endOfFile():
    let request = receive()
    let methodName = request["method"].getStr()
    if not request.hasKey("id"):
      doAssert methodName in ["session/cancel", "$/cancel_request"]
      continue
    if methodName == "authenticate":
      doAssert authTests
      doAssert request["params"]["methodId"].getStr() == "headless"
      if request["params"].hasKey("_meta"):
        doAssert request["params"]["_meta"] == %*{"headless":{"token":"fixture-only", "nested":[true, 7]}}
      else:
        doAssert request["params"] == %*{"methodId":"headless"}
      send(%*{"jsonrpc":"2.0", "id":request["id"], "result":{}})
    elif methodName == "session/new":
      doAssert request["params"].hasKey("mcpServers")
      var response = %*{"sessionId": "raw-session"}
      if sessionTests: response["configOptions"] = catalog("a")
      send(%*{"jsonrpc": "2.0", "id": request["id"], "result": response})
    elif methodName == "session/set_config_option":
      doAssert sessionTests
      doAssert request["params"]["value"].getStr() == "b"
      lateConfig = request["id"]
    elif methodName == "session/close":
      send(%*{"jsonrpc":"2.0", "id":request["id"],
        "error":{"code": -32002, "message":"Session already gone"}})
    elif methodName == "session/list":
      send(%*{"jsonrpc":"2.0", "id":request["id"], "result":{"sessions":[
        {"sessionId":"stored", "cwd":getTempDir(), "title":"Dormant"}]}})
    elif methodName == "session/prompt":
      let text = request["params"]["prompt"][0]["text"].getStr()
      case text
      of "late-config":
        doAssert lateConfig != nil
        send(%*{"jsonrpc":"2.0", "id":lateConfig, "result":{"configOptions":catalog("b")}})
        send(%*{"jsonrpc":"2.0", "method":"session/update", "params":{
          "sessionId":"raw-session", "update":{"sessionUpdate":"config_option_update",
            "configOptions":catalog("c")}}})
        send(%*{"jsonrpc":"2.0", "id":request["id"], "result":{"stopReason":"end_turn"}})
      of "cwd-env":
        send(%*{"jsonrpc": "2.0", "method": "session/update", "params": {
          "sessionId": "raw-session", "update": {"sessionUpdate": "agent_message_chunk",
          "content": {"type": "text", "text": getCurrentDir() & ":" & getEnv("ACPORT_LAUNCH_TEST")}}}})
        send(%*{"jsonrpc": "2.0", "id": request["id"], "result": {"stopReason": "end_turn"}})
      of "die": quit(7)
      of "incomplete":
        stdout.write("{\"jsonrpc\":")
        stdout.flushFile()
        return
      of "invalid-response":
        send(%*{"jsonrpc": "2.0", "id": request["id"], "result": {}, "error": {}})
      of "rpc-error":
        send(%*{"jsonrpc":"2.0", "id":request["id"],
          "error":{"code": -32001, "message":"Fixture error", "data":{"fixture":true}}})
      of "bad-result":
        send(%*{"jsonrpc":"2.0", "id":request["id"], "result":{"stopReason":"future"}})
      of "reply-and-exit":
        send(%*{"jsonrpc":"2.0", "method":"session/update", "params":{
          "sessionId":"raw-session", "update":{"sessionUpdate":"agent_message_chunk",
            "content":{"type":"text", "text":"done"}}}})
        send(%*{"jsonrpc":"2.0", "id":request["id"], "result":{"stopReason":"end_turn"}})
        return
      of "permission":
        send(%*{"jsonrpc": "2.0", "id": "peer-permission", "method": "session/request_permission",
          "params": {"sessionId": "raw-session", "toolCall": {"toolCallId": "t"}, "options": []}})
        let decision = receive()
        doAssert decision["id"].getStr() == "peer-permission"
        doAssert decision["result"]["outcome"]["outcome"].getStr() == "cancelled"
        send(%*{"jsonrpc": "2.0", "id": request["id"], "result": {"stopReason": "end_turn"}})
      else:
        stderr.write(repeat("diagnostic\n", 15000))
        stderr.flushFile()
        send(%*{"jsonrpc": "2.0", "method": "session/update", "params": {
          "sessionId": "raw-session", "update": {"sessionUpdate": "agent_message_chunk",
          "content": {"type": "text", "text": "line one\n雪🙂"}}}}, true)
        send(%*{"jsonrpc": "2.0", "id": request["id"], "result": {"stopReason": "end_turn"}})

main()
