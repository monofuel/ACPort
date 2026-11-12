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
  doAssert initialization["jsonrpc"].getStr() == "2.0"
  doAssert initialization["method"].getStr() == "initialize"
  doAssert initialization["params"]["clientCapabilities"] == newJObject()
  send(%*{"jsonrpc": "2.0", "id": initialization["id"], "result": {
    "protocolVersion": (if paramCount() > 0: 2 else: 1),
    "agentCapabilities": {}}})
  while not stdin.endOfFile():
    let request = receive()
    let methodName = request["method"].getStr()
    if not request.hasKey("id"):
      doAssert methodName in ["session/cancel", "$/cancel_request"]
      continue
    if methodName == "session/new":
      doAssert request["params"].hasKey("mcpServers")
      send(%*{"jsonrpc": "2.0", "id": request["id"], "result": {"sessionId": "raw-session"}})
    elif methodName == "session/prompt":
      let text = request["params"]["prompt"][0]["text"].getStr()
      case text
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
