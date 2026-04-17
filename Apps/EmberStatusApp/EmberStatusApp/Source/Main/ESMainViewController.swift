import UIKit
import EmberCore
import OSLog
#if os(iOS) && !targetEnvironment(macCatalyst)
import BackgroundTasks
#endif
#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

enum ESBackgroundRefresh {
    static let taskIdentifier = "com.github.1dustindavis.EmberStatusApp.refresh"
    static let fastInterval: TimeInterval = 60
    static let slowInterval: TimeInterval = 15 * 60
}

@MainActor
final class ESAppRuntime {
    static let shared = ESAppRuntime()
    private(set) var store: ESAppSessionStore?

    func sharedStore() -> ESAppSessionStore {
        if let store {
            return store
        }
        let store = ESAppSessionStore()
        self.store = store
        return store
    }

    func install(store: ESAppSessionStore) {
        self.store = store
    }
}

fileprivate enum ESRefreshReason: String {
    case manual
    case foregroundTimer
    case foregroundActivation
    case backgroundTask
}

@MainActor
private final class ESRefreshOrchestrator {
    private weak var store: ESAppSessionStore?
    private var pollingTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    private var isSceneActive = true

    init(store: ESAppSessionStore) {
        self.store = store
    }

    @MainActor
    deinit {
        stop()
    }

    func start() {
        startPollingLoop()
        startTickerLoop()
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        tickerTask?.cancel()
        tickerTask = nil
    }

    func setSceneActive(_ isActive: Bool) {
        isSceneActive = isActive
        if isActive {
            start()
            triggerImmediateRefresh(reason: .foregroundActivation)
        }
    }

    func triggerImmediateRefresh(reason: ESRefreshReason) {
        Task { @MainActor [weak self] in
            guard let self, let store else { return }
            _ = await store.runManagedRefresh(reason: reason)
        }
    }

    private func startPollingLoop() {
        if pollingTask != nil { return }
        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pollingTask = nil }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled, isSceneActive, let store else { continue }
                _ = await store.runManagedRefresh(reason: .foregroundTimer)
            }
        }
    }

    private func startTickerLoop() {
        if tickerTask != nil { return }
        tickerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.tickerTask = nil }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, isSceneActive, let store else { continue }
                await store.handleFreshnessTick(now: Date())
            }
        }
    }
}

#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
@MainActor
private final class ESMugActivityManager {
    private struct MaterialState: Equatable {
        var liquidState: String
        var currentTempC: Double?
        var batteryPercent: Int?
        var isCharging: Bool?
        var lastUpdatedAt: Date
    }

    private let logger = Logger(subsystem: "com.github.1dustindavis.EmberStatusApp", category: "LiveActivity")
    private let defaults = UserDefaults.standard
    private let managedActivityIDDefaultsKey = "es.liveActivity.managedID"
    private var activity: Activity<EmberMugActivityAttributes>?
    private let staleCutoffSeconds = 5 * 60
    private var lastPublishedMaterialState: MaterialState?
    private var lastShouldShow: Bool?
    private var didInitialCleanup = false

    func handle(snapshot: MugSessionCoordinator.Snapshot, secondsSinceLastUpdate: Int) async {
        await updateActivity(snapshot: snapshot, secondsSinceLastUpdate: secondsSinceLastUpdate)
    }

    private func updateActivity(snapshot: MugSessionCoordinator.Snapshot, secondsSinceLastUpdate: Int) async {
        await performInitialCleanupIfNeeded()

        let connected = snapshot.status.connectionState == .connected
        let activeLiquid = isActiveLiquid(snapshot.status.liquidState)
        let isFreshEnough = secondsSinceLastUpdate <= staleCutoffSeconds
        let shouldShow = connected && activeLiquid && isFreshEnough

        guard shouldShow else {
            if lastShouldShow != false {
                logger.notice("[LiveActivity] skipped connected=\(connected) activeLiquid=\(activeLiquid) fresh=\(isFreshEnough) secondsSinceLastUpdate=\(secondsSinceLastUpdate)")
            }
            lastShouldShow = false
            await endActivityIfNeeded()
            return
        }
        lastShouldShow = true

        if activity == nil {
            let existing = Activity<EmberMugActivityAttributes>.activities
            let savedManagedID = defaults.string(forKey: managedActivityIDDefaultsKey)

            if let savedManagedID,
               let restored = existing.first(where: { $0.id == savedManagedID }) {
                activity = restored
                logger.notice("[LiveActivity] restored managed id=\(restored.id, privacy: .public)")
            } else if existing.count == 1 {
                activity = existing.first
                if let restored = activity {
                    logger.notice("[LiveActivity] restored single existing id=\(restored.id, privacy: .public)")
                }
            } else if !existing.isEmpty {
                for existing in existing {
                    logger.notice("[LiveActivity] ending stale unknown id=\(existing.id, privacy: .public)")
                    await existing.end(nil, dismissalPolicy: .immediate)
                }
                defaults.removeObject(forKey: managedActivityIDDefaultsKey)
            }
        }

        await endExtraActivitiesKeepingCurrent()

        let mugName = snapshot.identity?.name ?? "Ember Mug"
        let contentState = EmberMugActivityAttributes.ContentState(
            liquidState: snapshot.status.liquidState?.displayName ?? "Unknown",
            currentTempC: snapshot.status.currentTempC,
            batteryPercent: snapshot.status.batteryPercent,
            isCharging: snapshot.status.isCharging,
            secondsSinceLastUpdate: secondsSinceLastUpdate,
            lastUpdatedAt: snapshot.status.lastUpdated
        )
        let materialState = MaterialState(
            liquidState: contentState.liquidState,
            currentTempC: contentState.currentTempC,
            batteryPercent: contentState.batteryPercent,
            isCharging: contentState.isCharging,
            lastUpdatedAt: contentState.lastUpdatedAt
        )
        let contentChanged = (lastPublishedMaterialState != materialState)

        do {
            let staleDate = snapshot.status.lastUpdated.addingTimeInterval(TimeInterval(staleCutoffSeconds))
            let content = ActivityContent(state: contentState, staleDate: staleDate)
            if let activity {
                if contentChanged {
                    await activity.update(content)
                    lastPublishedMaterialState = materialState
                    defaults.set(activity.id, forKey: managedActivityIDDefaultsKey)
                    logger.notice("[LiveActivity] updated id=\(activity.id, privacy: .public) liquid=\(contentState.liquidState, privacy: .public)")
                }
            } else {
                let attributes = EmberMugActivityAttributes(mugName: mugName)
                activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
                if let activity {
                    lastPublishedMaterialState = materialState
                    defaults.set(activity.id, forKey: managedActivityIDDefaultsKey)
                    logger.notice("[LiveActivity] started id=\(activity.id, privacy: .public) mug=\(mugName, privacy: .public)")
                }
            }
        } catch {
            logger.error("[LiveActivity] update failed error=\(error.localizedDescription)")
        }
    }

    private func isActiveLiquid(_ value: LiquidState?) -> Bool {
        guard let value else { return false }
        switch value {
        case .heating, .cooling:
            return true
        case .empty, .filling, .unknown:
            return false
        }
    }

    private func endActivityIfNeeded() async {
        if let activity {
            logger.notice("[LiveActivity] ending current id=\(activity.id, privacy: .public)")
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        await endExtraActivitiesKeepingCurrent()
        self.activity = nil
        self.lastPublishedMaterialState = nil
        defaults.removeObject(forKey: managedActivityIDDefaultsKey)
    }

    private func endExtraActivitiesKeepingCurrent() async {
        for existing in Activity<EmberMugActivityAttributes>.activities where existing.id != activity?.id {
            logger.notice("[LiveActivity] ending extra id=\(existing.id, privacy: .public)")
            await existing.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func performInitialCleanupIfNeeded() async {
        guard !didInitialCleanup else { return }
        didInitialCleanup = true

        let existing = Activity<EmberMugActivityAttributes>.activities
        if existing.isEmpty {
            defaults.removeObject(forKey: managedActivityIDDefaultsKey)
            return
        }

        logger.notice("[LiveActivity] initial cleanup count=\(existing.count, privacy: .public)")
        for stale in existing {
            logger.notice("[LiveActivity] initial cleanup ending id=\(stale.id, privacy: .public)")
            await stale.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
        lastPublishedMaterialState = nil
        defaults.removeObject(forKey: managedActivityIDDefaultsKey)
    }

    func forceEnd() {
        Task { @MainActor in
            await self.endActivityIfNeeded()
        }
    }
}
#else
@MainActor
private final class ESMugActivityManager {
    func handle(snapshot: MugSessionCoordinator.Snapshot, secondsSinceLastUpdate: Int) async {}
}
#endif

@MainActor
final class ESAppSessionStore {
    struct ViewState {
        var snapshot: MugSessionCoordinator.Snapshot
        var discoveredMugs: [MugIdentity]
        var isScanning: Bool
        var lastErrorMessage: String?
        var autoConnectEnabled: Bool
        var preferredAutoConnectMugID: UUID?
        var capturedFixtureCount: Int
        var lastCapturedFixtureID: String?
        var captureGroupsSummary: String
        var secondsSinceLastUpdate: Int
        var isStatusStale: Bool
        var lastRefreshAttempt: Date?
        var lastRefreshSucceededAt: Date?
        var lastRefreshErrorMessage: String?
    }

    private enum ViewError: Error, LocalizedError {
        case scanTimedOut
        case refreshTimedOut

        var errorDescription: String? {
            switch self {
            case .scanTimedOut:
                return "Scan timed out. Please try again."
            case .refreshTimedOut:
                return "Refresh timed out. Please try again."
            }
        }
    }

    private enum AutoConnectError: Error, LocalizedError {
        case mugNotFound

        var errorDescription: String? {
            switch self {
            case .mugNotFound:
                return "Saved mug was not found nearby for auto-connect."
            }
        }
    }

    private enum DefaultsKey {
        static let autoConnectEnabled = "es.autoConnectEnabled"
        static let preferredMugID = "es.preferredMugID"
    }

    private var observerBlocks: [UUID: (ViewState) -> Void] = [:]
    private let coordinator: MugSessionCoordinator
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.github.1dustindavis.EmberStatusApp", category: "SessionStore")
    private var autoConnectTask: Task<Void, Never>?
    private var backgroundRefreshTask: Task<Bool, Never>?
    private var isRefreshInFlight = false
    private var disconnectedRefreshFailures = 0
    private lazy var refreshOrchestrator = ESRefreshOrchestrator(store: self)
    private let activityManager = ESMugActivityManager()
    private let staleThresholdSeconds = 60
    private let refreshTimeoutSeconds = 20.0

    var didRefresh: ((Date) -> Void)?
    var didFailRefresh: ((Error) -> Void)?
    var didTransitionLiquidState: ((LiquidState?, LiquidState?) -> Void)?

    private struct CapturedFixtureRecord {
        let stateLabel: String
        let sampleIndex: Int
        let fixture: HardwareRegressionCapture
    }

    private var capturedFixtures: [CapturedFixtureRecord] = []
    private var captureCountsByStateLabel: [String: Int] = [:]

    private(set) var viewState: ViewState {
        didSet {
            notifyObservers()
        }
    }

    init(
        coordinator: MugSessionCoordinator = MugSessionCoordinator(bluetooth: CoreBluetoothManager()),
        defaults: UserDefaults = .standard
    ) {
        self.coordinator = coordinator
        self.defaults = defaults
        self.viewState = ViewState(
            snapshot: coordinator.snapshot,
            discoveredMugs: [],
            isScanning: false,
            lastErrorMessage: nil,
            autoConnectEnabled: defaults.bool(forKey: DefaultsKey.autoConnectEnabled),
            preferredAutoConnectMugID: UUID(uuidString: defaults.string(forKey: DefaultsKey.preferredMugID) ?? ""),
            capturedFixtureCount: 0,
            lastCapturedFixtureID: nil,
            captureGroupsSummary: "--",
            secondsSinceLastUpdate: 0,
            isStatusStale: false,
            lastRefreshAttempt: nil,
            lastRefreshSucceededAt: nil,
            lastRefreshErrorMessage: nil
        )

        coordinator.onSnapshotChanged = { [weak self] next in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let previousLiquidState = self.viewState.snapshot.status.liquidState
                self.viewState.snapshot = next
                self.updateFreshnessMetadata(now: Date())
                if previousLiquidState != next.status.liquidState {
                    self.didTransitionLiquidState?(previousLiquidState, next.status.liquidState)
                }
                await self.activityManager.handle(snapshot: next, secondsSinceLastUpdate: self.viewState.secondsSinceLastUpdate)
                let selectedID = next.identity?.id.uuidString ?? "none"
                self.logger.debug("[Store] snapshot updated state=\(String(describing: next.status.connectionState)) selected=\(selectedID)")
            }
        }
        coordinator.startConnectionEventListening()
        refreshOrchestrator.start()
        updateFreshnessMetadata(now: Date())
        Task { @MainActor in
            await self.activityManager.handle(
                snapshot: self.coordinator.snapshot,
                secondsSinceLastUpdate: self.viewState.secondsSinceLastUpdate
            )
        }

        if viewState.autoConnectEnabled {
            startAutoConnectIfNeeded()
        }
    }

    @MainActor
    deinit {
        coordinator.stopConnectionEventListening()
        coordinator.onSnapshotChanged = nil
        autoConnectTask?.cancel()
        backgroundRefreshTask?.cancel()
        refreshOrchestrator.stop()
    }

    func addObserver(_ observer: @escaping (ViewState) -> Void) -> UUID {
        let token = UUID()
        observerBlocks[token] = observer
        observer(viewState)
        return token
    }

    func removeObserver(_ token: UUID?) {
        guard let token else { return }
        observerBlocks[token] = nil
    }

    func scan() {
        guard !viewState.isScanning else { return }
        viewState.isScanning = true
        viewState.lastErrorMessage = nil

        Task {
            do {
                let devices = try await withTimeout(seconds: 12) {
                    try await self.coordinator.scanAndRankDevices()
                }
                self.viewState.discoveredMugs = devices
                self.viewState.lastErrorMessage = devices.isEmpty ? "Scan completed: no mugs found nearby." : nil
                self.viewState.isScanning = false
                self.logger.notice("[Store] scan completed count=\(devices.count)")
            } catch {
                self.viewState.lastErrorMessage = error.localizedDescription
                self.viewState.isScanning = false
                self.logger.error("[Store] scan failed error=\(error.localizedDescription)")
            }
        }
    }

    func connect(to mug: MugIdentity) {
        Task {
            do {
                try await coordinator.connect(to: mug)
                viewState.lastErrorMessage = nil
                if viewState.autoConnectEnabled {
                    setPreferredAutoConnectMug(id: mug.id)
                }
                logger.notice("[Store] connect succeeded id=\(mug.id.uuidString)")
            } catch {
                viewState.lastErrorMessage = error.localizedDescription
                logger.error("[Store] connect failed id=\(mug.id.uuidString) error=\(error.localizedDescription)")
            }
        }
    }

    func disconnect() {
        Task {
            await coordinator.disconnect()
            logger.notice("[Store] disconnect requested")
        }
    }

    func refresh() {
        refreshOrchestrator.triggerImmediateRefresh(reason: .manual)
    }

    func setSceneActive(_ isActive: Bool) {
        logger.notice("[Store] scene active=\(isActive)")
        refreshOrchestrator.setSceneActive(isActive)
        if !isActive {
            cancelBackgroundRefreshIfNeeded()
            scheduleBackgroundRefresh()
        }
    }

    func handleFreshnessTick(now: Date = Date()) async {
        updateFreshnessMetadata(now: now)
        await activityManager.handle(snapshot: viewState.snapshot, secondsSinceLastUpdate: viewState.secondsSinceLastUpdate)
    }

    @discardableResult
    fileprivate func runManagedRefresh(reason: ESRefreshReason) async -> Bool {
        guard !isRefreshInFlight else {
            logger.notice("[Store] refresh skipped reason=\(reason.rawValue, privacy: .public) inFlight=true")
            return false
        }

        isRefreshInFlight = true
        viewState.lastRefreshAttempt = Date()

        defer {
            isRefreshInFlight = false
            updateFreshnessMetadata(now: Date())
        }

        guard !Task.isCancelled else { return false }

        do {
            if coordinator.status.connectionState != .connected {
                guard await reconnectForManagedRefreshIfNeeded() else {
                    throw AutoConnectError.mugNotFound
                }
            }

            try await withTimeout(seconds: refreshTimeoutSeconds, timeoutError: ViewError.refreshTimedOut) {
                try await self.coordinator.refresh()
            }
            let refreshedAt = Date()
            viewState.lastErrorMessage = nil
            viewState.lastRefreshSucceededAt = refreshedAt
            viewState.lastRefreshErrorMessage = nil
            disconnectedRefreshFailures = 0
            await activityManager.handle(snapshot: coordinator.snapshot, secondsSinceLastUpdate: viewState.secondsSinceLastUpdate)
            didRefresh?(refreshedAt)
            logger.notice("[Store] refresh succeeded reason=\(reason.rawValue, privacy: .public)")
            scheduleBackgroundRefresh()
            return true
        } catch {
            viewState.lastErrorMessage = error.localizedDescription
            viewState.lastRefreshErrorMessage = error.localizedDescription
            if coordinator.status.connectionState != .connected {
                disconnectedRefreshFailures += 1
                if disconnectedRefreshFailures >= 3 {
                    activityManager.forceEnd()
                }
            } else {
                disconnectedRefreshFailures = 0
            }
            didFailRefresh?(error)
            logger.error("[Store] refresh failed reason=\(reason.rawValue, privacy: .public) error=\(error.localizedDescription)")
            return false
        }
    }

    func performBackgroundRefresh() async -> Bool {
        backgroundRefreshTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.runManagedRefresh(reason: .backgroundTask)
        }
        backgroundRefreshTask = task
        let success = await task.value
        backgroundRefreshTask = nil
        return success
    }

    func cancelBackgroundRefreshIfNeeded() {
        backgroundRefreshTask?.cancel()
    }

    func setAutoConnectEnabled(_ isEnabled: Bool) {
        viewState.autoConnectEnabled = isEnabled
        defaults.set(isEnabled, forKey: DefaultsKey.autoConnectEnabled)

        if !isEnabled {
            autoConnectTask?.cancel()
            autoConnectTask = nil
            return
        }

        if let selected = viewState.snapshot.identity {
            setPreferredAutoConnectMug(id: selected.id)
        }
        startAutoConnectIfNeeded()
    }

    func canEnableAutoConnect() -> Bool {
        viewState.autoConnectEnabled || viewState.snapshot.identity != nil
    }

    func preferredAutoConnectMugName() -> String {
        if let preferredID = viewState.preferredAutoConnectMugID,
           let found = viewState.discoveredMugs.first(where: { $0.id == preferredID }) {
            return found.name ?? preferredID.uuidString
        }

        return viewState.snapshot.identity?.name
            ?? viewState.preferredAutoConnectMugID?.uuidString
            ?? "None"
    }

    func captureFixtureSample(stateLabel: String, notes: String?) async throws {
        let trimmedLabel = stateLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else {
            throw NSError(
                domain: "ESAppSessionStore",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "State label is required."]
            )
        }

        let normalizedLabel = Self.normalizedStateLabel(trimmedLabel)
        let sampleIndex = (captureCountsByStateLabel[normalizedLabel] ?? 0) + 1
        let timestamp = Self.captureIDDateFormatter.string(from: Date())
        let captureID = "hardware-\(timestamp)-\(normalizedLabel)-s\(String(format: "%02d", sampleIndex))"
        let resolvedNotes = (notes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? notes!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "Captured state: \(trimmedLabel)."

        let capture = try await coordinator.captureRegressionFixture(captureID: captureID, notes: resolvedNotes)
        capturedFixtures.append(CapturedFixtureRecord(stateLabel: normalizedLabel, sampleIndex: sampleIndex, fixture: capture))
        captureCountsByStateLabel[normalizedLabel] = sampleIndex
        viewState.capturedFixtureCount = capturedFixtures.count
        viewState.captureGroupsSummary = Self.captureGroupsSummary(from: captureCountsByStateLabel)
        viewState.lastCapturedFixtureID = capture.captureID
        viewState.lastErrorMessage = nil
    }

    func exportCapturedFixturesJSON() throws -> String {
        guard !capturedFixtures.isEmpty else {
            throw NSError(
                domain: "ESAppSessionStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No captures collected yet."]
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let sortedFixtures = capturedFixtures
            .sorted {
                if $0.stateLabel == $1.stateLabel {
                    if $0.sampleIndex == $1.sampleIndex {
                        return $0.fixture.captureID < $1.fixture.captureID
                    }
                    return $0.sampleIndex < $1.sampleIndex
                }
                return $0.stateLabel < $1.stateLabel
            }
            .map(\.fixture)

        let data = try encoder.encode(sortedFixtures)
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "ESAppSessionStore",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode captured fixtures as UTF-8."]
            )
        }
        return json
    }

    func clearCapturedFixtures() {
        capturedFixtures = []
        captureCountsByStateLabel = [:]
        viewState.capturedFixtureCount = 0
        viewState.lastCapturedFixtureID = nil
        viewState.captureGroupsSummary = "--"
    }

    private static let captureIDDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    private static func normalizedStateLabel(_ raw: String) -> String {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = lower.map { character -> Character in
            if character.isLetter || character.isNumber { return character }
            return "-"
        }
        let collapsed = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "unlabeled" : collapsed
    }

    private static func captureGroupsSummary(from counts: [String: Int]) -> String {
        guard !counts.isEmpty else { return "--" }
        return counts
            .keys
            .sorted()
            .map { "\($0): \(counts[$0] ?? 0)" }
            .joined(separator: ", ")
    }

    private func updateFreshnessMetadata(now: Date) {
        let seconds = max(0, Int(now.timeIntervalSince(viewState.snapshot.status.lastUpdated)))
        viewState.secondsSinceLastUpdate = seconds
        viewState.isStatusStale = seconds >= staleThresholdSeconds
    }

    private func startAutoConnectIfNeeded() {
        guard viewState.autoConnectEnabled else { return }
        guard let preferredID = viewState.preferredAutoConnectMugID else { return }

        let state = viewState.snapshot.status.connectionState
        if state == .connected || state == .connecting {
            return
        }

        autoConnectTask?.cancel()
        autoConnectTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.runAutoConnectFlow(for: preferredID)
        }
    }

    private func runAutoConnectFlow(for preferredID: UUID, maxAttempts: Int = 3) async -> Bool {
        let preferredIdentity = MugIdentity(
            id: preferredID,
            name: (viewState.snapshot.identity?.id == preferredID ? viewState.snapshot.identity?.name : nil)
        )

        // Fast path: if CoreBluetooth can resolve the peripheral by identifier,
        // this avoids a full scan cycle and reconnects more quickly.
        do {
            try await coordinator.connect(to: preferredIdentity)
            viewState.lastErrorMessage = nil
            logger.notice("[Store] auto-connect direct succeeded id=\(preferredID.uuidString)")
            return true
        } catch {
            logger.notice("[Store] auto-connect direct failed id=\(preferredID.uuidString) error=\(error.localizedDescription)")
        }

        for attempt in 1...maxAttempts {
            if Task.isCancelled { return false }

            do {
                let devices = try await withTimeout(seconds: 12) {
                    try await self.coordinator.scanAndRankDevices()
                }
                self.viewState.discoveredMugs = devices

                guard let mug = devices.first(where: { $0.id == preferredID }) else {
                    throw AutoConnectError.mugNotFound
                }

                try await self.coordinator.connect(to: mug)
                self.viewState.lastErrorMessage = nil
                self.logger.notice("[Store] auto-connect succeeded attempt=\(attempt) id=\(preferredID.uuidString)")
                return true
            } catch {
                self.viewState.lastErrorMessage = "Auto-connect attempt \(attempt) failed: \(error.localizedDescription)"
                self.logger.error("[Store] auto-connect failed attempt=\(attempt) id=\(preferredID.uuidString) error=\(error.localizedDescription)")
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
        return false
    }

    private func reconnectForManagedRefreshIfNeeded() async -> Bool {
        guard coordinator.status.connectionState != .connected else {
            return true
        }

        guard let preferredID = viewState.preferredAutoConnectMugID ?? viewState.snapshot.identity?.id else {
            return false
        }

        return await runAutoConnectFlow(for: preferredID, maxAttempts: 2)
    }

    func recommendedBackgroundRefreshInterval() -> TimeInterval {
        let status = viewState.snapshot.status
        let isConnected = status.connectionState == .connected
        let isThermallyActive: Bool
        switch status.liquidState {
        case .heating?, .cooling?:
            isThermallyActive = true
        default:
            isThermallyActive = false
        }
        return (isConnected && isThermallyActive) ? ESBackgroundRefresh.fastInterval : ESBackgroundRefresh.slowInterval
    }

    func shouldRunExtendedBackgroundRefreshLoop() -> Bool {
        let status = viewState.snapshot.status
        guard status.connectionState == .connected else { return false }
        switch status.liquidState {
        case .heating?, .cooling?:
            return true
        default:
            return false
        }
    }

    private func scheduleBackgroundRefresh() {
#if os(iOS) && !targetEnvironment(macCatalyst)
        ESAppDelegate.scheduleBackgroundRefreshTask(earliestIn: recommendedBackgroundRefreshInterval())
#endif
    }

    private func setPreferredAutoConnectMug(id: UUID) {
        viewState.preferredAutoConnectMugID = id
        defaults.set(id.uuidString, forKey: DefaultsKey.preferredMugID)
    }

    private func notifyObservers() {
        let state = viewState
        for observer in observerBlocks.values {
            observer(state)
        }
    }

    private func withTimeout<T: Sendable>(
        seconds: Double,
        timeoutError: Error = ViewError.scanTimedOut,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw timeoutError
            }

            guard let first = try await group.next() else {
                throw timeoutError
            }
            group.cancelAll()
            return first
        }
    }
}

final class ESMainViewController: UIViewController {
    private var store: ESAppSessionStore?
    private var observerToken: UUID?
    private var lastErrorMessage: String?
    private var secondsSinceLastUpdate = 0
    private var snapshot = MugSessionCoordinator.Snapshot(
        identity: nil,
        status: MugStatus(),
        diagnostics: MugDiagnostics(),
        capabilityMap: nil
    )

    private struct DetailRow {
        let title: String
        let value: String
    }

    private let navTitleLabel = UILabel()
    private let navSubtitleLabel = UILabel()
    private let navTitleStack = UIStackView()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let diagnosticsStack = UIStackView()
    private let parseWarningsLabel = UILabel()
    private let lastErrorLabel = UILabel()
    private let lastEventLabel = UILabel()
    private var rows: [DetailRow] = []

    init(store: ESAppSessionStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureUI()
        bindStoreIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        store?.setSceneActive(true)
    }

    private func configureUI() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .refresh,
            target: self,
            action: #selector(refreshTapped)
        )

        navTitleLabel.font = .preferredFont(forTextStyle: .headline)
        navTitleLabel.textAlignment = .center
        navTitleLabel.textColor = .label
        navTitleLabel.numberOfLines = 1

        navSubtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        navSubtitleLabel.textAlignment = .center
        navSubtitleLabel.textColor = .secondaryLabel
        navSubtitleLabel.numberOfLines = 1

        navTitleStack.axis = .vertical
        navTitleStack.alignment = .center
        navTitleStack.spacing = 0
        navTitleStack.addArrangedSubview(navTitleLabel)
        navTitleStack.addArrangedSubview(navSubtitleLabel)
        navigationItem.titleView = navTitleStack

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "StatusCell")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        tableView.tableFooterView = UIView()
        view.addSubview(tableView)

        diagnosticsStack.axis = .vertical
        diagnosticsStack.spacing = 4
        diagnosticsStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(diagnosticsStack)

        [parseWarningsLabel, lastErrorLabel, lastEventLabel].forEach { label in
            label.font = .preferredFont(forTextStyle: .caption2)
            label.numberOfLines = 1
            diagnosticsStack.addArrangedSubview(label)
        }
        parseWarningsLabel.textColor = .secondaryLabel
        lastErrorLabel.textColor = .secondaryLabel
        lastEventLabel.textColor = .tertiaryLabel

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: diagnosticsStack.topAnchor, constant: -8),

            diagnosticsStack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            diagnosticsStack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            diagnosticsStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6)
        ])
    }

    private func bindStoreIfNeeded() {
        guard observerToken == nil, let store else { return }
        observerToken = store.addObserver { [weak self] state in
            self?.snapshot = state.snapshot
            self?.lastErrorMessage = state.lastErrorMessage
            self?.secondsSinceLastUpdate = state.secondsSinceLastUpdate
            self?.renderSnapshot()
        }
    }

    private func renderSnapshot() {
        navTitleLabel.text = snapshot.identity?.name ?? "No Mug Selected"
        navSubtitleLabel.text = String(describing: snapshot.status.connectionState).capitalized
        rows = [
            DetailRow(title: "Liquid State", value: formattedLiquidState(snapshot.status.liquidState)),
            DetailRow(title: "Current Temp", value: formattedTemperature(snapshot.status.currentTempC)),
            DetailRow(title: "Target Temp", value: formattedTemperature(snapshot.status.targetTempC)),
            DetailRow(title: "Battery", value: snapshot.status.batteryPercent.map { "\($0)%" } ?? "--"),
            DetailRow(title: "Charging", value: snapshot.status.isCharging.map { $0 ? "Yes" : "No" } ?? "--"),
            DetailRow(title: "Updated", value: formattedUpdated(secondsSinceLastUpdate))
        ]
        parseWarningsLabel.text = "Parse warnings: \(snapshot.diagnostics.parseWarnings.count)"
        lastErrorLabel.text = "Last error: \(lastErrorMessage ?? "--")"
        lastEventLabel.text = "Last event: \(snapshot.diagnostics.connectionEvents.last?.message ?? "--")"
        tableView.reloadData()
    }

    private func formattedTemperature(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.2f°C", value)
    }

    private func formattedLiquidState(_ value: LiquidState?) -> String {
        guard let value else { return "--" }
        return value.displayName
    }

    private func formattedUpdated(_ elapsedSeconds: Int) -> String {
        if elapsedSeconds < 60 {
            return "\(elapsedSeconds) sec ago"
        }

        let elapsedMinutes = elapsedSeconds / 60
        if elapsedMinutes < 60 {
            return "\(elapsedMinutes) min ago"
        }

        let elapsedHours = elapsedMinutes / 60
        if elapsedHours < 24 {
            let unit = elapsedHours == 1 ? "hour" : "hours"
            return "\(elapsedHours) \(unit) ago"
        }

        let elapsedDays = elapsedHours / 24
        let unit = elapsedDays == 1 ? "day" : "days"
        return "\(elapsedDays) \(unit) ago"
    }

    @objc
    private func refreshTapped() {
        store?.refresh()
    }
}

extension ESMainViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "StatusCell", for: indexPath)
        let row = rows[indexPath.row]

        var config = UIListContentConfiguration.valueCell()
        config.text = row.title
        config.secondaryText = row.value
        config.textProperties.color = .label
        config.secondaryTextProperties.color = row.title == "Last Event" ? .tertiaryLabel : .secondaryLabel
        config.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = config
        cell.selectionStyle = .none

        return cell
    }
}

final class ESConnectionViewController: UIViewController {
    private struct DetailRow {
        let title: String
        let value: String
    }

    private var store: ESAppSessionStore?
    private var observerToken: UUID?

    private var discoveredMugs: [MugIdentity] = []
    private var isScanning = false
    private var snapshot = MugSessionCoordinator.Snapshot(
        identity: nil,
        status: MugStatus(),
        diagnostics: MugDiagnostics(),
        capabilityMap: nil
    )
    private var lastErrorMessage: String?
    private var autoConnectEnabled = false
    private var preferredMugText = "None"
    private var capturedFixtureCount = 0
    private var lastCapturedFixtureID: String?
    private var captureGroupsSummary = "--"
    private var isStatusStale = false
    private var lastRefreshAttempt: Date?
    private var lastRefreshSucceededAt: Date?
    private var lastRefreshErrorMessage: String?
    private var rows: [DetailRow] = []

    private let autoConnectSwitch = UISwitch()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private lazy var scanBarButtonItem = UIBarButtonItem(
        title: "Scan",
        style: .plain,
        target: self,
        action: #selector(scanTapped)
    )
    private lazy var connectBarButtonItem = UIBarButtonItem(
        title: "Connect",
        style: .plain,
        target: self,
        action: #selector(connectTapped)
    )
    private lazy var disconnectBarButtonItem = UIBarButtonItem(
        title: "Disconnect",
        style: .plain,
        target: self,
        action: #selector(disconnectTapped)
    )
    private lazy var captureBarButtonItem = UIBarButtonItem(
        title: "Capture",
        style: .plain,
        target: self,
        action: #selector(captureTapped)
    )
    private lazy var exportBarButtonItem = UIBarButtonItem(
        title: "Export",
        style: .plain,
        target: self,
        action: #selector(exportTapped)
    )

    init(store: ESAppSessionStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Connection"
        view.backgroundColor = .systemBackground
        configureUI()
        bindStoreIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        store?.setSceneActive(true)
    }

    private func configureUI() {
        navigationItem.rightBarButtonItems = [scanBarButtonItem, captureBarButtonItem, exportBarButtonItem]
        navigationItem.leftBarButtonItems = [connectBarButtonItem, disconnectBarButtonItem]

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ConnectionCell")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        tableView.tableFooterView = UIView()
        view.addSubview(tableView)

        autoConnectSwitch.onTintColor = .systemBlue
        autoConnectSwitch.addTarget(self, action: #selector(autoConnectToggled), for: .valueChanged)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func bindStoreIfNeeded() {
        guard observerToken == nil, let store else { return }
        observerToken = store.addObserver { [weak self] state in
            guard let self else { return }
            self.snapshot = state.snapshot
            self.discoveredMugs = state.discoveredMugs
            self.isScanning = state.isScanning
            self.lastErrorMessage = state.lastErrorMessage
            self.autoConnectEnabled = state.autoConnectEnabled
            self.preferredMugText = store.preferredAutoConnectMugName()
            self.capturedFixtureCount = state.capturedFixtureCount
            self.lastCapturedFixtureID = state.lastCapturedFixtureID
            self.captureGroupsSummary = state.captureGroupsSummary
            self.isStatusStale = state.isStatusStale
            self.lastRefreshAttempt = state.lastRefreshAttempt
            self.lastRefreshSucceededAt = state.lastRefreshSucceededAt
            self.lastRefreshErrorMessage = state.lastRefreshErrorMessage
            self.renderState()
        }
    }

    private func renderState() {
        let rssiValue: String
        if let rssi = snapshot.identity?.rssi {
            rssiValue = "\(rssi) dBm"
        } else {
            rssiValue = "--"
        }

        rows = [
            DetailRow(title: "Selected Mug", value: snapshot.identity?.name ?? "None"),
            DetailRow(title: "RSSI", value: rssiValue),
            DetailRow(title: "Connection", value: String(describing: snapshot.status.connectionState).capitalized),
            DetailRow(title: "Discovered Mugs", value: "\(discoveredMugs.count)"),
            DetailRow(title: "Preferred Mug", value: preferredMugText),
            DetailRow(title: "Captured Fixtures", value: "\(capturedFixtureCount)"),
            DetailRow(title: "Capture Groups", value: captureGroupsSummary),
            DetailRow(title: "Last Capture ID", value: lastCapturedFixtureID ?? "--"),
            DetailRow(title: "Status Freshness", value: isStatusStale ? "Stale" : "Fresh"),
            DetailRow(title: "Last Refresh Attempt", value: formattedTimestamp(lastRefreshAttempt)),
            DetailRow(title: "Last Refresh Success", value: formattedTimestamp(lastRefreshSucceededAt)),
            DetailRow(title: "Last Refresh Error", value: lastRefreshErrorMessage ?? "--"),
            DetailRow(title: "Last Error", value: lastErrorMessage ?? "--"),
            DetailRow(title: "Last Event", value: snapshot.diagnostics.connectionEvents.last?.message ?? "--")
        ]

        autoConnectSwitch.isOn = autoConnectEnabled
        autoConnectSwitch.isEnabled = store?.canEnableAutoConnect() ?? false
        tableView.reloadData()

        scanBarButtonItem.title = isScanning ? "Scanning..." : "Scan"
        scanBarButtonItem.isEnabled = !isScanning
        connectBarButtonItem.isEnabled = !discoveredMugs.isEmpty
        disconnectBarButtonItem.isEnabled = snapshot.identity != nil
        captureBarButtonItem.isEnabled = snapshot.status.connectionState == .connected
        exportBarButtonItem.isEnabled = capturedFixtureCount > 0
    }

    private func formattedTimestamp(_ date: Date?) -> String {
        guard let date else { return "--" }
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    @objc
    private func scanTapped() {
        store?.scan()
    }

    @objc
    private func connectTapped() {
        guard !discoveredMugs.isEmpty else {
            lastErrorMessage = "No discovered mugs. Tap Scan first."
            renderState()
            return
        }

        let sheet = UIAlertController(title: "Connect to Mug", message: nil, preferredStyle: .actionSheet)
        for mug in discoveredMugs {
            let title = mug.name ?? mug.id.uuidString
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.store?.connect(to: mug)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = sheet.popoverPresentationController {
            popover.barButtonItem = connectBarButtonItem
        }

        present(sheet, animated: true)
    }

    @objc
    private func disconnectTapped() {
        store?.disconnect()
    }

    @objc
    private func autoConnectToggled() {
        guard let store else { return }

        if autoConnectSwitch.isOn, !store.canEnableAutoConnect() {
            autoConnectSwitch.setOn(false, animated: true)
            lastErrorMessage = "Connect to a mug first, then enable auto-connect."
            renderState()
            return
        }

        store.setAutoConnectEnabled(autoConnectSwitch.isOn)
    }

    @objc
    private func captureTapped() {
        let alert = UIAlertController(
            title: "Capture Hardware Fixture",
            message: "Enter a state label. Repeated captures of the same label are grouped automatically.",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "State label (e.g., idle-empty, overshoot-cooling)"
            field.text = ""
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
        }
        alert.addTextField { field in
            field.placeholder = "Notes (optional)"
            field.text = ""
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Capture", style: .default) { [weak self, weak alert] _ in
            guard let self, let alert else { return }
            let stateLabel = alert.textFields?.first?.text ?? ""
            let notes = alert.textFields?.dropFirst().first?.text
            self.runCapture(stateLabel: stateLabel, notes: notes)
        })

        present(alert, animated: true)
    }

    @objc
    private func exportTapped() {
        guard let store else { return }

        do {
            let json = try store.exportCapturedFixturesJSON()
            UIPasteboard.general.string = json
            let alert = UIAlertController(
                title: "Copied Fixture JSON",
                message: "Captured fixtures JSON was copied to clipboard. Paste into Tests/EmberCoreTests/Fixtures/hardware-regression-fixtures.json.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            alert.addAction(UIAlertAction(title: "Clear Captures", style: .destructive) { _ in
                store.clearCapturedFixtures()
            })
            present(alert, animated: true)
        } catch {
            lastErrorMessage = error.localizedDescription
            renderState()
        }
    }

    private func runCapture(stateLabel: String, notes: String?) {
        guard let store else { return }

        Task {
            do {
                try await store.captureFixtureSample(stateLabel: stateLabel, notes: notes)
                lastErrorMessage = nil
                renderState()
            } catch {
                lastErrorMessage = "Capture failed: \(error.localizedDescription)"
                renderState()
            }
        }
    }
}

extension ESConnectionViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count + 1
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ConnectionCell", for: indexPath)
        cell.selectionStyle = .none

        if indexPath.row == 0 {
            var config = UIListContentConfiguration.valueCell()
            config.text = "Auto-connect on launch"
            config.secondaryText = nil
            cell.contentConfiguration = config
            cell.accessoryView = autoConnectSwitch
            return cell
        }

        let row = rows[indexPath.row - 1]
        var config = UIListContentConfiguration.valueCell()
        config.text = row.title
        config.secondaryText = row.value
        config.secondaryTextProperties.numberOfLines = 0
        config.secondaryTextProperties.color = row.title == "Last Event" ? .tertiaryLabel : .secondaryLabel
        cell.contentConfiguration = config
        cell.accessoryView = nil

        return cell
    }
}

final class ESTabBarController: UITabBarController {
    private let store: ESAppSessionStore

    init(store: ESAppSessionStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let statusVC = UINavigationController(rootViewController: ESMainViewController(store: store))
        statusVC.tabBarItem = UITabBarItem(title: "Status", image: UIImage(systemName: "thermometer"), tag: 0)

        let connectionVC = UINavigationController(rootViewController: ESConnectionViewController(store: store))
        connectionVC.tabBarItem = UITabBarItem(title: "Connection", image: UIImage(systemName: "dot.radiowaves.left.and.right"), tag: 1)

        viewControllers = [statusVC, connectionVC]
    }
}

final class ESCatalystSidebarViewController: UITableViewController {
    enum Item: Int, CaseIterable {
        case status
        case connection

        var title: String {
            switch self {
            case .status:
                return "Status"
            case .connection:
                return "Connection"
            }
        }

        var symbolName: String {
            switch self {
            case .status:
                return "thermometer"
            case .connection:
                return "dot.radiowaves.left.and.right"
            }
        }
    }

    var onSelection: ((Item) -> Void)?
    private var selectedItem: Item = .status

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Ember Status"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "SidebarCell")
        tableView.backgroundColor = .secondarySystemBackground
        tableView.separatorStyle = .none
        tableView.selectRow(at: IndexPath(row: selectedItem.rawValue, section: 0), animated: false, scrollPosition: .none)
    }

    func select(_ item: Item) {
        selectedItem = item
        tableView.selectRow(at: IndexPath(row: item.rawValue, section: 0), animated: false, scrollPosition: .none)
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Item.allCases.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SidebarCell", for: indexPath)
        guard let item = Item(rawValue: indexPath.row) else { return cell }
        var config = cell.defaultContentConfiguration()
        config.text = item.title
        config.image = UIImage(systemName: item.symbolName)
        cell.contentConfiguration = config
        cell.accessoryType = (item == selectedItem) ? .checkmark : .none
        cell.backgroundColor = .clear
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let item = Item(rawValue: indexPath.row) else { return }
        selectedItem = item
        tableView.reloadData()
        onSelection?(item)
    }
}

final class ESCatalystSplitViewController: UISplitViewController {
    private let sidebarViewController = ESCatalystSidebarViewController(style: .insetGrouped)
    private let statusNavigationController: UINavigationController
    private let connectionNavigationController: UINavigationController

    init(store: ESAppSessionStore) {
        statusNavigationController = UINavigationController(rootViewController: ESMainViewController(store: store))
        connectionNavigationController = UINavigationController(rootViewController: ESConnectionViewController(store: store))
        super.init(style: .doubleColumn)
        primaryBackgroundStyle = .sidebar
        preferredDisplayMode = .oneBesideSecondary
        preferredSplitBehavior = .tile
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        sidebarViewController.onSelection = { [weak self] item in
            self?.setDetail(for: item)
        }

        let sidebarNavigationController = UINavigationController(rootViewController: sidebarViewController)
        setViewController(sidebarNavigationController, for: .primary)
        setDetail(for: .status)
        sidebarViewController.select(.status)
    }

    private func setDetail(for item: ESCatalystSidebarViewController.Item) {
        switch item {
        case .status:
            setViewController(statusNavigationController, for: .secondary)
        case .connection:
            setViewController(connectionNavigationController, for: .secondary)
        }
    }
}
