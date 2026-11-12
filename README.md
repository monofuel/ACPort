# ACPort

Nim library for [Agent Client Protocol](https://agentclientprotocol.com/)
clients and agents. A sibling to [MCPort](https://github.com/monofuel/MCPort).

## Status

Initial project foundation only. No ACP behavior is implemented yet.

The intended starting scope is ACP v1 over stdio, supporting both client and
agent roles, sessions, streamed updates, permission requests, and cancellation.
Protocol support belongs in ACPort; scheduling, retries, tickets, and worktree
management belong in applications such as Scriptorium.

## Development

Requires Nim 2.0 or newer, Nimby 0.2.3 or newer, and Make.
Use Nimby for dependencies; the `.nimble` file provides package metadata.
There are currently no package dependencies, so `nimby.lock` is empty.

Create a workspace in the parent of the checkout:

```sh
mkdir acport-workspace
cd acport-workspace
nimby create
git clone https://github.com/monofuel/ACPort.git
cd ACPort
make setup
make check
```

For an existing checkout, run `nimby create` from its parent directory first.
Project compiler settings live in `config.nims`; Nimby manages dependency paths
in the workspace's `nim.cfg`.

## License

MIT.
