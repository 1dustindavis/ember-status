# iOS App Shell

This repository ships `EmberCore` plus a UIKit iOS shell in `Apps/iOS/Sources`.

Implemented shell responsibilities:
- Scene-based UIKit startup (`AppDelegate` + `SceneDelegate`)
- Snapshot-driven status surface backed by `MugSessionCoordinator.Snapshot`
- Coordinator bind/unbind hooks for listener lifecycle wiring

Next production hardening steps:
- Inject a real CoreBluetooth-backed `BluetoothManaging` implementation
- Add permission UX and device-list interaction
- Add refresh/disconnect actions and richer diagnostics presentation
