import
  std/[json, unittest],
  acport

suite "ACP payloads":
  test "text and resource links use ACP discriminators":
    check textBlock("a\nb").toJsonNode() == %*{"type": "text", "text": "a\nb"}
    let link = resourceLink("file:///tmp/notes", "notes")
    check parseContent(link.toJsonNode()).uri == "file:///tmp/notes"

  test "raw content and metadata survive forwarding":
    let source = %*{"type": "_custom", "extra": [1, 2], "_meta": {"x": true}}
    let parsed = parseContent(source)
    check parsed.kind == unknownContent
    check parsed.toJsonNode() == source

  test "tool patches preserve absence versus null":
    let source = %*{"sessionId": "s", "update": {"sessionUpdate": "tool_call_update",
      "toolCallId": "t", "rawOutput": nil, "_meta": {"trace": "x"}}}
    let update = parseUpdate(source)
    check update.kind == toolCallUpdate
    check not update.tool.raw.hasKey("status")
    check update.toJsonNode() == source

  test "unknown session updates retain the complete payload":
    let source = %*{"sessionId": "s", "update": {"sessionUpdate": "usage_update", "size": 42}}
    check parseUpdate(source).kind == unknownUpdate
    check parseUpdate(source).toJsonNode() == source

  test "prompt validation rejects malformed required fields":
    expect AcpRpcError: discard parsePrompt(%*{"sessionId": "s"})
    expect AcpRpcError: discard parseContent(%*{"type": "text"})
    expect AcpRpcError: discard parseSessionRequest(%*{"cwd": "/tmp"})

  test "stop reasons round trip":
    for reason in StopReason:
      check parsePromptResponse(PromptResponse(stopReason: reason).toJsonNode()).stopReason == reason

  test "permission rejection remains a selected option":
    let outcome = parsePermissionOutcome(%*{"outcome": {"outcome": "selected", "optionId": "reject"}})
    check outcome.optionId == "reject"
    check outcome.toJsonNode()["outcome"]["outcome"].getStr() == "selected"

  test "session/new always contains mcpServers and load result has no sessionId":
    check SessionRequest(cwd: "/tmp").toJsonNode() == %*{"cwd": "/tmp", "mcpServers": []}
    check SessionResponse(sessionId: "s").toJsonNode(true) == newJObject()

  test "permission options preserve nested metadata":
    let source = %*{"sessionId": "s", "toolCall": {"toolCallId": "t"},
      "options": [{"optionId": "reject", "name": "Reject", "kind": "reject_once",
      "_meta": {"trace": "nested"}}], "_meta": {"trace": "outer"}}
    check parsePermission(source).toJsonNode() == source

  test "diffs and terminal references have typed content":
    let diff = parseToolContent(%*{"type": "diff", "path": "/tmp/new", "oldText": nil, "newText": "hello"})
    check diff.kind == diffToolContent
    check diff.diff.newText == "hello"
    check parseToolContent(%*{"type": "terminal", "terminalId": "term-1"}).terminalId == "term-1"

  test "update envelope metadata survives independently of nested metadata":
    let source = %*{"sessionId": "s", "_meta": {"a": 1}, "update": {
      "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "x"},
      "_meta": {"b": 2}}}
    check parseUpdate(source).toJsonNode() == source
