# Repository Review (Two-Pass)

Date: 2026-04-14

## Scope reviewed
- Core library (`Sources/EmberCore/*`)
- App shells (`Apps/iOS`, `Apps/macOS`)
- Tests (`Tests/EmberCoreTests/*`)
- Package/build metadata and documentation (`Package.swift`, `README.md`, `plan.md`)

---

## Pass 1 — Architecture, correctness, and guardrails

### What is strong
1. **Read-only boundary is explicit and enforced.**
   - `BluetoothManaging` exposes no write API.
   - `ReadOnlyGuardrailTests` scans source for write-oriented symbols.
   - Characteristic catalog clearly separates readable and notifiable IDs.
2. **Defensive parsing is practical and resilient.**
   - Parser functions validate payload lengths and battery range.
   - Unknown liquid state values are preserved via `.unknown(UInt8)`.
3. **Reducer-based status updates are clean and stable.**
   - Event-based partial update model avoids full-state churn.
   - Per-field parse warnings are stored and can be cleared on successful future parse.
4. **Use-case orchestration is cohesive.**
   - `MugSessionCoordinator` handles scan/connect/read/subscribe/reconnect in one place.
   - `Snapshot` makes UI integration straightforward.
5. **Test suite aligns with design goals.**
   - Parsing, reducer semantics, guardrails, compatibility modes, and connection-event listener lifecycle are covered.

### Key risks / issues
1. **Potential race conditions from mutable coordinator state.**
   - `MugSessionCoordinator` is a class with mutable state (`status`, `diagnostics`, `selectedMug`) that is touched from async methods and from a detached listener task.
   - It is marked `@unchecked Sendable`, which bypasses compiler safety checks.
   - This is acceptable for a prototype, but should be hardened before production.
2. **`disconnect()` lifecycle edge case.**
   - `disconnect()` returns early when no `selectedMug`; in that path it does not force-reset `status.connectionState` to `.disconnected`.
   - If state drifts due to a prior event, UI could display stale connection state.
3. **Event listener refresh coupling is limited.**
   - `handleConnectionEvent(_:)` updates connection state and reconnect behavior, but does not react to push-event payloads by refreshing dependent fields.
   - The MVP plan says notifications should drive passive status updates.
4. **Warning accumulation in permissive mode may grow noisy.**
   - `parseWarnings` stores unique stringified warnings forever (bounded only by uniqueness).
   - If payload variants occur over time, warning set can grow and become less actionable.

---

## Pass 2 — Re-review from additional angles

### Angle A: API ergonomics and extension readiness
- Positive: public model types are compact and understandable.
- Gap: no protocol or façade around `MugSessionCoordinator`; dependency inversion is only at the Bluetooth layer.
- Recommendation: add a small `MugSessionCoordinating` protocol to support easier mocking in app/UI tests.

### Angle B: Test strategy depth
- Positive: integration tests include reconnect and compatibility-mode behavior.
- Gaps to add:
  1. `scanAndRankDevices()` behavior when availability is not `.poweredOn` (error and state assertion).
  2. `disconnect()` idempotency and state reset expectations.
  3. Event log cap behavior (ensuring oldest records are dropped after 50).
  4. Notification subscription conditionality based on capabilities.

### Angle C: Product/UX alignment to plan
- Positive: app shells are intentionally thin and read-only.
- Gap: current app shells are mostly snapshot displays and do not yet represent scan/list/connect/refresh workflows called out in `plan.md`.
- Recommendation: move from static snapshot binding examples to a minimal real flow state machine in view model.

### Angle D: Operational diagnostics
- Positive: diagnostics include characteristic discovery and event history.
- Gap: parse warnings are plain strings; structured warning metadata (field + code + timestamp + payload length) would improve troubleshooting and analytics.

---

## Focused next steps (concise)
1. **Concurrency hardening:** convert `MugSessionCoordinator` to an `actor` or confine all mutation to `@MainActor`.
2. **Notification-driven refresh:** on supported push events, trigger targeted reads to keep status live without manual refresh.
3. **Lifecycle consistency:** make `disconnect()` always set `status.connectionState = .disconnected` and clear session state, even if no selected mug.
4. **Diagnostics quality:** replace warning strings with a structured warning type and add optional bounded retention.
5. **Test expansion:** add edge-case tests for unavailable Bluetooth, listener/event log caps, and disconnect idempotency.
