import
  std/[json, os]

proc send(node: JsonNode) =
  ## Write one independent wire message without ACPort codecs.
  stdout.writeLine($node)
  stdout.flushFile()

proc receive(): JsonNode =
  ## Read one independent wire message without ACPort dispatch.
  parseJson(stdin.readLine())

proc call(id, methodName: string, params: JsonNode): JsonNode =
  ## Issue a literal reverse request and verify response correlation.
  send(%*{"jsonrpc": "2.0", "id": id, "method": methodName, "params": params})
  result = receive()
  doAssert result["id"].getStr() == id

proc main() =
  ## Validate reverse filesystem and terminal behavior against literal v1 wire messages.
  let
    init = receive()
    mode = if paramCount() > 0: paramStr(1) else: "host"
  send(%*{"jsonrpc": "2.0", "id": init["id"], "result": {"protocolVersion": 1, "agentCapabilities": {}}})
  let setup = receive()
  let root = setup["params"]["cwd"].getStr()
  send(%*{"jsonrpc": "2.0", "id": setup["id"], "result": {"sessionId": "raw-coverage"}})
  let prompt = receive()
  if mode == "unsupported":
    for methodName in ["fs/read_text_file", "fs/write_text_file", "terminal/create", "terminal/output",
        "terminal/wait_for_exit", "terminal/kill", "terminal/release"]:
      let response = call(methodName, methodName, %*{"sessionId": "raw-coverage", "path": root / "file",
        "content": "text", "terminalId": "t", "command": "false"})
      doAssert response["error"]["code"].getInt() == -32601
  else:
    doAssert init["params"]["clientCapabilities"]["fs"] == %*{"readTextFile": true, "writeTextFile": true}
    doAssert init["params"]["clientCapabilities"]["terminal"].getBool()
    let read = call("read", "fs/read_text_file", %*{"sessionId": "raw-coverage", "path": root / "unsaved.txt",
      "line": 2, "limit": 1, "_meta": {"read": true}})
    doAssert read["result"] == %*{"content": "buffer", "_meta": {"read": true}}
    let write = call("write", "fs/write_text_file", %*{"sessionId": "raw-coverage", "path": root / "written.txt",
      "content": "wire text", "_meta": {"write": true}})
    doAssert write["result"]["_meta"] == %*{"write": true}
    let create = call("create", "terminal/create", %*{"sessionId": "raw-coverage", "command": "/bin/sh",
      "args": ["-c", "printf ready; sleep 30"], "cwd": root, "outputByteLimit": 5,
      "env": [{"name": "ACPORT_TERMINAL_TEST", "value": "yes"}], "_meta": {"create": true}})
    doAssert create["result"]["_meta"] == %*{"create": true}
    let terminal = create["result"]["terminalId"].getStr()
    let params = %*{"sessionId": "raw-coverage", "terminalId": terminal, "_meta": {"control": true}}
    send(%*{"jsonrpc": "2.0", "id": "waiting", "method": "terminal/wait_for_exit", "params": params})
    let control = receive()
    if mode == "cancel-wait":
      doAssert control["method"].getStr() == "session/cancel"
      send(%*{"jsonrpc": "2.0", "method": "$/cancel_request", "params": {"requestId": "waiting"}})
      let cancelled = receive()
      doAssert cancelled["id"].getStr() == "waiting" and cancelled.hasKey("error")
      let output = call("snapshot", "terminal/output", params)
      doAssert not output["result"].hasKey("exitStatus")
      discard call("kill", "terminal/kill", params)
    else:
      doAssert control["method"].getStr() == "_control"
      let output = call("snapshot", "terminal/output", params)
      doAssert not output["result"].hasKey("exitStatus")
      let operation = if mode == "release-wait": "terminal/release" else: "terminal/kill"
      send(%*{"jsonrpc": "2.0", "id": "kill", "method": operation, "params": params})
      var seenKill, seenWait: bool
      for i in 0 .. 1:
        let reply = receive()
        if reply["id"].getStr() == "waiting":
          if mode == "release-wait": doAssert reply.hasKey("error")
          else: doAssert reply["result"]["signal"].kind == JString
          seenWait = true
        elif reply["id"].getStr() == "kill":
          doAssert reply["result"]["_meta"] == %*{"control": true}
          seenKill = true
      doAssert seenKill and seenWait
      if mode != "release-wait":
        let retained = call("retained", "terminal/output", params)
        doAssert retained["result"]["exitStatus"]["signal"].kind == JString
    if mode != "release-wait": discard call("release", "terminal/release", params)
    let invalid = call("released", "terminal/output", params)
    doAssert invalid["error"]["code"].getInt() == -32602
    if mode != "cancel-wait": send(%*{"jsonrpc": "2.0", "id": control["id"], "result": {"controlled": true}})
  send(%*{"jsonrpc": "2.0", "id": prompt["id"],
    "result": {"stopReason": (if mode == "cancel-wait": "cancelled" else: "end_turn")}})
  while not stdin.endOfFile(): discard receive()

main()
