# Ember Status (Read-Only)

Current implementation status for the read-only Ember status architecture described in `plan.md`:

- `EmberCore` domain models for identity + status.
- Defensive parse-only protocol decoders.
- Event-driven status reducer that supports partial updates.
- BLE transport abstractions for scan/connect/read/notify without write APIs.
- Read-only session coordinator use case for scan ranking, connect, capability discovery, refresh, notifications, reconnect, and explicit connection-event listener lifecycle controls.
- Diagnostics model with protocol compatibility mode (`strict` / `permissive`) and connection event tracking.
- Thin SwiftUI iOS/macOS app shell examples wired to coordinator snapshots and listener lifecycle hooks.
- Unit + integration tests for parsing, reducer behavior, strict/permissive warning behavior across refresh cycles, use-case workflows, and read-only guardrails.

## Run checks

```bash
swift test
```
