# macOS App Shell

This repository ships `EmberCore` plus a UIKit shell for Mac Catalyst in `Apps/macOS/Sources`.

Implemented shell responsibilities:
- Scene-based UIKit startup (`AppDelegate` + `SceneDelegate`)
- Snapshot-driven status rendering via `MugSessionCoordinator.Snapshot`
- Mac Catalyst toolbar integration for desktop-style sidebar behavior

Next production hardening steps:
- Wire CoreBluetooth transport implementation
- Add connect/reconnect controls and device selection
- Expand diagnostics UI and copy/export affordance
