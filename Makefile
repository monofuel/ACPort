.PHONY: setup check test test-arc test-orc integration-setup integration-test examples build/fixture-agent build/raw-agent build/session-agent

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

test: build/fixture-agent build/raw-agent build/session-agent
	$(NIM) r --out:build/test_protocol tests/test_protocol.nim
	$(NIM) r --out:build/test_stdio tests/test_stdio.nim
	$(NIM) r --out:build/test_sessions tests/test_sessions.nim

test-arc:
	ACPORT_TEST_MM=arc $(MAKE) test

test-orc:
	ACPORT_TEST_MM=orc $(MAKE) test

build/codex-relay: tests/codex_relay.nim src/acport.nim src/acport/*.nim
	mkdir -p build
	$(NIM) c --out:$@ $<

integration-setup:
	npm install --prefix build/integration-tools --ignore-scripts --no-audit --no-fund --save-exact @agentclientprotocol/codex-acp@2.6.0

integration-test: build/codex-relay
	$(NIM) r --out:build/integration_codex tests/integration_codex.nim

examples:
	mkdir -p build
	$(NIM) c --out:build/example-agent examples/agent.nim
	$(NIM) c --out:build/example-client examples/client.nim
