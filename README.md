# Ember Status (Read-Only)

Initial implementation for the read-only Ember status architecture described in `plan.md`:

- `EmberCore` domain models for identity + status.
- Defensive parse-only protocol decoders.
- Event-driven status reducer that supports partial updates.
- Unit tests for parsing and reducer behavior.

## Run checks

```bash
swift test
```
