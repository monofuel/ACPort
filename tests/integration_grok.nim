import
  std/unittest,
  ./[agent_profiles, integration_live]

preflight(grok)

suite "live Grok ACP":
  test "direct client": runLive(grok, false)
  test "agent/client relay": runLive(grok, true)
