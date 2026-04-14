# Ember Status App Plan (Read-Only)

## 1) Product scope (Read-only only)

### MVP (read-only)
- Discover nearby Ember mugs over BLE.
- Connect to one mug at a time.
- Display live status:
  - current temperature
  - target temperature (read-only display)
  - battery percentage
  - charging state
  - liquid/heating state (if available)
- Show connection quality (RSSI) and last-updated timestamp.
- Manual refresh + passive live updates via notifications.
- Clear error states:
  - Bluetooth unavailable
  - permissions denied
  - mug disconnected
  - unsupported/unknown firmware payloads.

### Explicit non-goals
- No write operations at all (no set target temp, no LED controls, no rename, etc.).
- No attempt to pair/configure mug features.
- No vendor account/cloud dependency.

## 2) Technical architecture

### Repo structure (recommended)
- `EmberStatus/` (app project/workspace)
- `Packages/EmberCore/` (shared logic for iOS + macOS)
  - `Bluetooth/` (CoreBluetooth abstraction)
  - `Protocol/` (UUID map + read parsers only)
  - `Domain/` (read-only state models)
  - `UseCases/` (scan/connect/subscribe/read flows)
- `Apps/iOS/`
- `Apps/macOS/`
- `Tests/EmberCoreTests/`

### Runtime layers
1. **Transport layer** — wraps CoreBluetooth primitives.
2. **Protocol layer** — parse-only decoders (`Data -> typed values`).
3. **State layer** — immutable/read-oriented `MugStatus`.
4. **UI layer** — SwiftUI views bound to observable state.

## 3) Read-only data model

Define:

- `MugIdentity`
  - `id: UUID`
  - `name: String?`
  - `rssi: Int?`
- `MugStatus`
  - `currentTempC: Double?`
  - `targetTempC: Double?` *(display only)*
  - `batteryPercent: Int?`
  - `isCharging: Bool?`
  - `liquidState: LiquidState?`
  - `connectionState: ConnectionState`
  - `lastUpdated: Date`
  - `rawDiagnostics: [String: String]` *(optional for troubleshooting)*

Design for partial data and unknown fields to handle firmware variance gracefully.

## 4) BLE workflow (read-only implementation)

### Scan
- Start scan from user action.
- Rank devices by RSSI.
- Optional filter by known Ember identifiers/services when available.

### Connect
- Connect selected mug.
- Discover all relevant services/characteristics.
- Build a capability map from what is actually present.

### Read + notify (no writes)
- Initial full read of known status characteristics.
- Subscribe to notification/event characteristics.
- On event, re-read dependent read-only characteristics.
- Update a single observable state atomically to avoid UI flicker.

### Disconnect handling
- Manual disconnect: immediate stop + clear active subscriptions.
- Unexpected disconnect: optional auto-reconnect with capped retry/backoff.

## 5) iOS and macOS specifics

### iOS
- Configure Bluetooth usage descriptions in `Info.plist`.
- Foreground-first behavior for MVP.
- If background mode is added later, treat it as “best effort” due to OS scan limits.

### macOS
- Shared CoreBluetooth logic with platform-specific app shell.
- Consider menu bar quick-view later (still read-only).

## 6) Reliability and observability

Since protocol behavior can vary by firmware:
- Use defensive decoders:
  - validate length/type
  - never crash on malformed payload
  - map unknown enum values safely.
- Add a lightweight diagnostics panel:
  - discovered services/characteristics
  - last N parse warnings
  - timestamped connection events
- Keep a “protocol compatibility mode” setting (strict vs permissive parsing).

## 7) Testing strategy (read-only focused)

### Unit tests
- Parse fixtures for each supported status characteristic.
- Unknown/short payload tests.
- State-reducer tests for event-driven refresh.

### Integration tests
- Mock peripheral adapter for deterministic scan/connect/read/notify scenarios.
- Regression fixtures from real hardware captures (anonymized).

### Manual hardware matrix
- Mug idle / heating / charging / near-empty
- Connection drop + reconnect
- App foreground/background transitions
- iOS + macOS parity checks for displayed values

## 8) UX plan (simple and robust)

Primary screen:
- Device list (name/RSSI/connect button)

Status screen:
- Current temp
- Target temp (read-only badge)
- Battery + charging indicator
- Liquid state
- Last update timestamp
- Connection status + reconnect action

Settings/diagnostics:
- Bluetooth permission status
- Debug panel toggle
- “Copy diagnostics” for troubleshooting

## 9) Guardrails to enforce read-only

To guarantee no drift into write features:
- Protocol layer should expose **no write API**.
- Code review checklist item:
  - “No characteristic writes introduced.”
