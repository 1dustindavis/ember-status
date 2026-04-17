import UIKit
import EmberCore
import OSLog

@MainActor
final class ESAppSessionStore {
    struct ViewState {
        var snapshot: MugSessionCoordinator.Snapshot
        var discoveredMugs: [MugIdentity]
        var isScanning: Bool
        var lastErrorMessage: String?
        var autoConnectEnabled: Bool
        var preferredAutoConnectMugID: UUID?
    }

    private enum ViewError: Error, LocalizedError {
        case scanTimedOut

        var errorDescription: String? {
            switch self {
            case .scanTimedOut:
                return "Scan timed out. Please try again."
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
            preferredAutoConnectMugID: UUID(uuidString: defaults.string(forKey: DefaultsKey.preferredMugID) ?? "")
        )

        coordinator.onSnapshotChanged = { [weak self] next in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.viewState.snapshot = next
                let selectedID = next.identity?.id.uuidString ?? "none"
                self.logger.debug("[Store] snapshot updated state=\(String(describing: next.status.connectionState)) selected=\(selectedID)")
            }
        }
        coordinator.startConnectionEventListening()

        if viewState.autoConnectEnabled {
            startAutoConnectIfNeeded()
        }
    }

    deinit {
        coordinator.stopConnectionEventListening()
        coordinator.onSnapshotChanged = nil
        autoConnectTask?.cancel()
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
        Task {
            do {
                try await coordinator.refresh()
                viewState.lastErrorMessage = nil
                logger.notice("[Store] refresh succeeded")
            } catch {
                viewState.lastErrorMessage = error.localizedDescription
                logger.error("[Store] refresh failed error=\(error.localizedDescription)")
            }
        }
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
            await self.runAutoConnectFlow(for: preferredID)
        }
    }

    private func runAutoConnectFlow(for preferredID: UUID) async {
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            if Task.isCancelled { return }

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
                return
            } catch {
                self.viewState.lastErrorMessage = "Auto-connect attempt \(attempt) failed: \(error.localizedDescription)"
                self.logger.error("[Store] auto-connect failed attempt=\(attempt) id=\(preferredID.uuidString) error=\(error.localizedDescription)")
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
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
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ViewError.scanTimedOut
            }

            guard let first = try await group.next() else {
                throw ViewError.scanTimedOut
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
    private var snapshot = MugSessionCoordinator.Snapshot(
        identity: nil,
        status: MugStatus(),
        diagnostics: MugDiagnostics(),
        capabilityMap: nil
    )

    private let nameLabel = UILabel()
    private let connectionLabel = UILabel()
    private let liquidStateLabel = UILabel()
    private let currentTempLabel = UILabel()
    private let targetTempLabel = UILabel()
    private let batteryLabel = UILabel()
    private let chargingLabel = UILabel()
    private let warningLabel = UILabel()
    private let lastErrorLabel = UILabel()
    private let lastEventLabel = UILabel()
    private let refreshButton = UIButton(type: .system)

    private lazy var labels: [UILabel] = [
        nameLabel,
        connectionLabel,
        liquidStateLabel,
        currentTempLabel,
        targetTempLabel,
        batteryLabel,
        chargingLabel,
        warningLabel,
        lastErrorLabel,
        lastEventLabel
    ]

    init(store: ESAppSessionStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Status"
        view.backgroundColor = .systemBackground
        configureUI()
        bindStoreIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutSubviewsManually()
    }

    private func configureUI() {
        labels.forEach { label in
            label.numberOfLines = 1
            label.font = .preferredFont(forTextStyle: .body)
            view.addSubview(label)
        }
        nameLabel.font = .preferredFont(forTextStyle: .headline)
        lastErrorLabel.font = .preferredFont(forTextStyle: .caption1)
        lastEventLabel.font = .preferredFont(forTextStyle: .caption1)

        refreshButton.setTitle("Refresh", for: .normal)
        refreshButton.addTarget(self, action: #selector(refreshTapped), for: .touchUpInside)
        view.addSubview(refreshButton)
    }

    private func bindStoreIfNeeded() {
        guard observerToken == nil, let store else { return }
        observerToken = store.addObserver { [weak self] state in
            self?.snapshot = state.snapshot
            self?.lastErrorMessage = state.lastErrorMessage
            self?.renderSnapshot()
        }
    }

    private func layoutSubviewsManually() {
        let inset = view.layoutMargins
        let top = view.safeAreaInsets.top + 16
        let width = max(0, view.bounds.width - inset.left - inset.right)
        let lineHeight: CGFloat = 22
        let spacing: CGFloat = 8
        let buttonHeight: CGFloat = 34

        refreshButton.frame = CGRect(x: inset.left, y: top, width: 110, height: buttonHeight)

        let labelsTop = top + buttonHeight + 18
        for (index, label) in labels.enumerated() {
            let y = labelsTop + CGFloat(index) * (lineHeight + spacing)
            label.frame = CGRect(x: inset.left, y: y, width: width, height: lineHeight)
        }
    }

    private func renderSnapshot() {
        nameLabel.text = snapshot.identity?.name ?? "No mug selected"
        connectionLabel.text = "Connection: \(String(describing: snapshot.status.connectionState))"
        liquidStateLabel.text = "Liquid state: \(formattedLiquidState(snapshot.status.liquidState))"
        currentTempLabel.text = "Current temp: \(formattedTemperature(snapshot.status.currentTempC))"
        targetTempLabel.text = "Target temp: \(formattedTemperature(snapshot.status.targetTempC))"
        batteryLabel.text = "Battery: \(snapshot.status.batteryPercent.map { "\($0)%" } ?? "--")"
        chargingLabel.text = "Charging: \(snapshot.status.isCharging.map { $0 ? "Yes" : "No" } ?? "--")"
        warningLabel.text = "Parse warnings: \(snapshot.diagnostics.parseWarnings.count)"
        lastErrorLabel.text = "Last error: \(lastErrorMessage ?? "--")"
        lastEventLabel.text = "Last event: \(snapshot.diagnostics.connectionEvents.last?.message ?? "--")"
    }

    private func formattedTemperature(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.2f°C", value)
    }

    private func formattedLiquidState(_ value: LiquidState?) -> String {
        guard let value else { return "--" }
        return value.displayName
    }

    @objc
    private func refreshTapped() {
        store?.refresh()
    }
}

final class ESConnectionViewController: UIViewController {
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

    private let selectedMugLabel = UILabel()
    private let connectionLabel = UILabel()
    private let discoveredLabel = UILabel()
    private let preferredMugLabel = UILabel()
    private let autoConnectLabel = UILabel()
    private let autoConnectSwitch = UISwitch()
    private let lastErrorLabel = UILabel()
    private let lastEventLabel = UILabel()

    private let scanButton = UIButton(type: .system)
    private let connectButton = UIButton(type: .system)
    private let disconnectButton = UIButton(type: .system)

    private lazy var labels: [UILabel] = [
        selectedMugLabel,
        connectionLabel,
        discoveredLabel,
        preferredMugLabel,
        autoConnectLabel,
        lastErrorLabel,
        lastEventLabel
    ]

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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutSubviewsManually()
    }

    private func configureUI() {
        labels.forEach { label in
            label.numberOfLines = 1
            label.font = .preferredFont(forTextStyle: .body)
            view.addSubview(label)
        }
        selectedMugLabel.font = .preferredFont(forTextStyle: .headline)
        autoConnectLabel.text = "Auto-connect on launch"
        lastErrorLabel.font = .preferredFont(forTextStyle: .caption1)
        lastEventLabel.font = .preferredFont(forTextStyle: .caption1)

        scanButton.setTitle("Scan", for: .normal)
        scanButton.addTarget(self, action: #selector(scanTapped), for: .touchUpInside)
        view.addSubview(scanButton)

        connectButton.setTitle("Connect", for: .normal)
        connectButton.addTarget(self, action: #selector(connectTapped), for: .touchUpInside)
        view.addSubview(connectButton)

        disconnectButton.setTitle("Disconnect", for: .normal)
        disconnectButton.addTarget(self, action: #selector(disconnectTapped), for: .touchUpInside)
        view.addSubview(disconnectButton)

        autoConnectSwitch.addTarget(self, action: #selector(autoConnectToggled), for: .valueChanged)
        view.addSubview(autoConnectSwitch)
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
            self.renderState()
        }
    }

    private func layoutSubviewsManually() {
        let inset = view.layoutMargins
        let top = view.safeAreaInsets.top + 16
        let width = max(0, view.bounds.width - inset.left - inset.right)
        let lineHeight: CGFloat = 22
        let spacing: CGFloat = 8
        let buttonHeight: CGFloat = 34
        let buttonWidth = min(110, (width - 16) / 3)

        scanButton.frame = CGRect(x: inset.left, y: top, width: buttonWidth, height: buttonHeight)
        connectButton.frame = CGRect(x: scanButton.frame.maxX + 8, y: top, width: buttonWidth, height: buttonHeight)
        disconnectButton.frame = CGRect(x: connectButton.frame.maxX + 8, y: top, width: buttonWidth, height: buttonHeight)

        let labelsTop = top + buttonHeight + 18
        for (index, label) in labels.enumerated() {
            let y = labelsTop + CGFloat(index) * (lineHeight + spacing)
            label.frame = CGRect(x: inset.left, y: y, width: width, height: lineHeight)
        }

        autoConnectSwitch.frame = CGRect(
            x: inset.left + width - autoConnectSwitch.intrinsicContentSize.width,
            y: autoConnectLabel.frame.minY - 4,
            width: autoConnectSwitch.intrinsicContentSize.width,
            height: autoConnectSwitch.intrinsicContentSize.height
        )
    }

    private func renderState() {
        selectedMugLabel.text = "Selected mug: \(snapshot.identity?.name ?? "None")"
        connectionLabel.text = "Connection: \(String(describing: snapshot.status.connectionState))"
        discoveredLabel.text = "Discovered mugs: \(discoveredMugs.count)"
        preferredMugLabel.text = "Preferred mug: \(preferredMugText)"
        lastErrorLabel.text = "Last error: \(lastErrorMessage ?? "--")"
        lastEventLabel.text = "Last event: \(snapshot.diagnostics.connectionEvents.last?.message ?? "--")"

        autoConnectSwitch.isOn = autoConnectEnabled
        autoConnectSwitch.isEnabled = store?.canEnableAutoConnect() ?? false

        scanButton.setTitle(isScanning ? "Scanning..." : "Scan", for: .normal)
        scanButton.isEnabled = !isScanning
        disconnectButton.isEnabled = snapshot.identity != nil
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
            popover.sourceView = connectButton
            popover.sourceRect = connectButton.bounds
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
