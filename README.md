# ACPort

![Racha beside a glowing crystal in an orbital relay chamber](static/relay_chamber.png "An orbital relay chamber")

**Bring coding agents into your Nim tools.**

ACPort implements the [Agent Client Protocol](https://agentclientprotocol.com/)
for Nim. Build an agent-powered editor, terminal application or workflow with
streamed responses, tool activity and permission prompts through a common
interface. It has been tested with Codex, Claude and Grok.

It works both ways: connect your application to existing agents, or build your
own Nim agent for ACP-compatible clients. A sibling of
[MCPort](https://github.com/monofuel/MCPort).

The library supports **ACP v1 over Linux stdio**, using synchronous APIs and
threads. Its only package dependency is [jsony](https://github.com/treeform/jsony).

## Try it

Requires Linux, Nim 2.0+, Nimby 0.2.3+ and Make. To connect to an existing agent,
its ACP executable must be installed and authenticated separately.

```sh
mkdir acport-workspace
cd acport-workspace
nimby create
git clone https://github.com/monofuel/ACPort.git
cd ACPort
make setup
make examples
```

For example, with `codex-acp` available on your PATH:

```sh
./build/example-client codex-acp "Summarize this project."
```

See the runnable [client](examples/client.nim) and [agent](examples/agent.nim)
examples for a starting point. API documentation lives in the source's Nimdoc
comments, starting with [acport](src/acport.nim).

## Development

```sh
make check
make test-arc
make test-orc
```

[Protocol coverage](COVERAGE.md) describes the supported ACP surface.
[Release notes](CHANGELOG.md) track changes between versions.

## License

MIT.
