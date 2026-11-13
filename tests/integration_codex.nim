import
  std/unittest,
  ./[agent_profiles, integration_live]

preflight(codex)

suite "live Codex ACP":
  test "direct client": runLive(codex, false)
  test "agent/client relay": runLive(codex, true)
