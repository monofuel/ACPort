.PHONY: setup check test test-arc test-orc integration-setup integration-test integration-test-codex integration-test-grok integration-test-claude examples build/fixture-agent build/raw-agent build/session-agent build/features-agent build/features-raw

NIM ?= nim

setup:
	nimby sync nimby.lock

check:
	$(NIM) check src/acport.nim

build/fixture-agent: tests/fixtures/agent.nim src/acport.nim src/acport/*.nim
	mkdir -p build
	$(NIM) c --out:$@ $<

build/raw-agent: tests/fixtures/raw_agent.nim
	mkdir -p build
	$(NIM) c --out:$@ $<

build/session-agent: tests/fixtures/session_agent.nim src/acport.nim src/acport/*.nim
	mkdir -p build
	$(NIM) c --out:$@ $<

build/features-agent: tests/fixtures/features_agent.nim src/acport.nim src/acport/*.nim
	mkdir -p build
	$(NIM) c --out:$@ $<

build/features-raw: tests/fixtures/features_raw.nim
	mkdir -p build
	$(NIM) c --out:$@ $<

test: build/fixture-agent build/raw-agent build/session-agent build/features-agent build/features-raw
	$(NIM) r --out:build/test_protocol tests/test_protocol.nim
	$(NIM) r --out:build/test_stdio tests/test_stdio.nim
	$(NIM) r --out:build/test_sessions tests/test_sessions.nim
	$(NIM) r --out:build/test_features tests/test_features.nim

test-arc:
	ACPORT_TEST_MM=arc $(MAKE) test

test-orc:
	ACPORT_TEST_MM=orc $(MAKE) test

build/agent-relay: tests/agent_relay.nim tests/agent_profiles.nim src/acport.nim src/acport/*.nim
	mkdir -p build
	$(NIM) c --out:$@ $<

integration-setup:
	npm install --prefix build/integration-tools --ignore-scripts --no-audit --no-fund --save-exact @agentclientprotocol/codex-acp@2.6.0 @agentclientprotocol/claude-agent-acp@0.106.0

integration-test: integration-test-codex integration-test-grok integration-test-claude

integration-test-codex: build/agent-relay
	$(NIM) r --out:build/integration_codex tests/integration_codex.nim

integration-test-grok: build/agent-relay
	$(NIM) r --out:build/integration_grok tests/integration_grok.nim

integration-test-claude: build/agent-relay
	$(NIM) r --out:build/integration_claude tests/integration_claude.nim

examples:
	mkdir -p build
	$(NIM) c --out:build/example-agent examples/agent.nim
	$(NIM) c --out:build/example-client examples/client.nim
