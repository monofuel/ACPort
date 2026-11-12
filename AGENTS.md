# ACPort

Nim library for Agent Client Protocol clients and agents, alongside MCPort.

- Keep the library small and dependencies minimal.
- Use synchronous APIs and threads. Do not introduce async or asyncdispatch.
- Use Nimby 0.2.3 or newer for dependency management, not Nimble.
- Create the Nimby workspace in the parent directory of the checkout.
- Keep project compiler settings in `config.nims` and commit `nimby.lock`.
- Run `make setup` to sync dependencies and `make check` to check the module.
- Run `make test-arc` and `make test-orc` for deterministic tests in both memory managers.
- Run `make integration-test` for real Codex tests. Missing prerequisites must fail, not skip.
- Use one import block, grouped standard library, third-party, then local modules.
- Put a concise `##` Nimdoc comment inside each procedure.
- Let errors propagate unless this layer can meaningfully handle them.
- Keep protocol types and dispatch separate from transports and application policy.
- Advertise only protocol capabilities the implementation actually handles.
- Keep stdio stdout exclusively for protocol messages; send diagnostics to stderr.

Linux stdio and core ACP v1 are the 1.0 surface. Keep application policy,
providers, persistence, and orchestration outside the library. Thread boundaries
must transfer owned shared buffers, never managed strings or JSON references.
