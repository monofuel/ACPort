# Changelog

## 1.3.0

- Add callback-backed filesystem and terminal requests in both protocol roles,
  with capability checks, cancellation, and reserved terminal control dispatch.
- Add session history deletion and logout with application-owned persistence and
  credential policy.
- Add terminal authentication descriptors and an explicit host-terminal helper
  that reconnects and reinitializes after successful login.
- Add additional workspace roots, append/override system prompts, rich prompt
  capability declarations, and MCP HTTP/SSE configuration declarations.
- Add negotiated notices and streamed compaction state with ordered owned
  snapshots and omission/null patch semantics.
- Preserve plan-entry, tool-location, diff, and permission-outcome metadata;
  accept the full unsigned usage and terminal-output-limit ranges.
- Extend independent wire fixtures and the callback-backed relay tests while
  preserving Linux stdio, synchronous threaded APIs, jsony, and the existing
  `UpdateKind` variants.
