import
  std/os,
  acport

proc printUpdate(update: SessionUpdate, userData: pointer) {.gcsafe.} =
  ## Print streamed agent text from the callback thread.
  if update.kind == agentMessageChunk and update.content.kind == textContent:
    stdout.write(update.content.text)
    stdout.flushFile()

proc main() =
  ## Connect to an installed ACP agent and run one prompt.
  if paramCount() < 2:
    quit("Usage: client <agent-executable> <prompt>", 1)
  let client = newAcpClient("acport-example", AcportVersion,
    ClientHandlers(onUpdate: printUpdate))
  defer: client.close()
  client.connect(paramStr(1))
  discard client.initialize()
  let session = client.newSession(getCurrentDir())
  discard session.prompt(paramStr(2))
  stdout.write("\n")

main()
