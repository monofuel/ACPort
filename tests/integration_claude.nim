import
  std/unittest,
  ./[agent_profiles, integration_live]

preflight(claude)

suite "live Claude ACP":
  test "direct client": runLive(claude, false)
  test "agent/client relay": runLive(claude, true)
