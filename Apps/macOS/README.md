# macOS App Shell

This repository ships `EmberCore` plus a thin SwiftUI macOS shell in `Apps/macOS/Sources/EmberStatusmacOSApp.swift`.

Implemented shell responsibilities:
- Shared snapshot-driven workflow via `MugSessionCoordinator.Snapshot`
- View-model bind/unbind lifecycle for coordinator ownership
- Event stream lifecycle hookup using coordinator listener APIs

Next production hardening steps:
- Wire CoreBluetooth transport implementation
- Add connect/reconnect controls and device selection
- Expand diagnostics UI and copy/export affordance
