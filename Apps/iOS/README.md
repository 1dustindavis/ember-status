# iOS App Shell

This repository ships `EmberCore` plus a thin SwiftUI iOS shell in `Apps/iOS/Sources/EmberStatusiOSApp.swift`.

Implemented shell responsibilities:
- Snapshot-driven status surface backed by `MugSessionCoordinator.Snapshot`
- View-model binding hooks for attaching/detaching a coordinator instance
- Explicit coordinator lifecycle wiring (`startConnectionEventListening` / `stopConnectionEventListening`)

Next production hardening steps:
- Inject a real CoreBluetooth-backed `BluetoothManaging` implementation
- Add permission UX and device-list interaction
- Add refresh/disconnect actions and richer diagnostics presentation
