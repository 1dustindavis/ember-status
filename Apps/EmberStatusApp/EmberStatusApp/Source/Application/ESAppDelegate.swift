import UIKit
#if os(iOS) && !targetEnvironment(macCatalyst)
import BackgroundTasks
import OSLog
#endif

@UIApplicationMain
class ESAppDelegate: UIResponder, UIApplicationDelegate {
#if os(iOS) && !targetEnvironment(macCatalyst)
    private static let logger = Logger(subsystem: "com.github.1dustindavis.EmberStatusApp", category: "BackgroundTask")
    private var immediateRefreshTaskID: UIBackgroundTaskIdentifier = .invalid
    private var immediateRefreshLoopTask: Task<Void, Never>?
    private let immediateRefreshLoopMaxDuration: TimeInterval = 10 * 60
#endif

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
#if os(iOS) && !targetEnvironment(macCatalyst)
        registerBackgroundRefreshTask()
        Self.scheduleBackgroundRefreshTask(earliestIn: ESBackgroundRefresh.slowInterval)
#endif
        return true
    }

#if os(iOS) && !targetEnvironment(macCatalyst)
    func applicationDidEnterBackground(_ application: UIApplication) {
        Self.logger.notice("[BGTask] applicationDidEnterBackground")
        handleBackgroundTransition(using: application, source: "appDelegate")
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        Self.logger.notice("[BGTask] applicationWillEnterForeground")
    }

    func handleSceneDidEnterBackground() {
        Self.logger.notice("[BGTask] sceneDidEnterBackground bridge")
        handleBackgroundTransition(using: UIApplication.shared, source: "sceneDelegate")
    }
#endif

#if os(iOS) && !targetEnvironment(macCatalyst)
    private func registerBackgroundRefreshTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: ESBackgroundRefresh.taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                Self.logger.error("[BGTask] received unexpected task type")
                task.setTaskCompleted(success: false)
                return
            }
            Self.logger.notice("[BGTask] handler invoked id=\(ESBackgroundRefresh.taskIdentifier)")
            self.handleBackgroundRefresh(task: refreshTask)
        }
        Self.logger.notice("[BGTask] registered id=\(ESBackgroundRefresh.taskIdentifier)")
    }

    private func handleBackgroundRefresh(task: BGAppRefreshTask) {
        task.expirationHandler = {
            Self.logger.error("[BGTask] expiration fired id=\(ESBackgroundRefresh.taskIdentifier)")
            Task { @MainActor in
                ESAppRuntime.shared.store?.cancelBackgroundRefreshIfNeeded()
            }
        }

        Task { @MainActor in
            let store = ESAppRuntime.shared.sharedStore()
            Self.logger.notice("[BGTask] refresh started")
            let success = await store.performBackgroundRefresh()
            let interval = store.recommendedBackgroundRefreshInterval()
            Self.scheduleBackgroundRefreshTask(earliestIn: interval)
            Self.logger.notice("[BGTask] refresh finished success=\(success)")
            task.setTaskCompleted(success: success)
        }
    }

    static func scheduleBackgroundRefreshTask(earliestIn interval: TimeInterval) {
        let request = BGAppRefreshTaskRequest(identifier: ESBackgroundRefresh.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.notice("[BGTask] scheduled earliestInSeconds=\(Int(interval))")
        } catch {
            logger.error("[BGTask] failed to schedule error=\(error.localizedDescription)")
        }
    }

    private func runImmediateBackgroundRefresh(application: UIApplication) {
        immediateRefreshLoopTask?.cancel()
        immediateRefreshLoopTask = nil

        if immediateRefreshTaskID != .invalid {
            application.endBackgroundTask(immediateRefreshTaskID)
            immediateRefreshTaskID = .invalid
        }

        immediateRefreshTaskID = application.beginBackgroundTask(withName: "com.github.1dustindavis.EmberStatusApp.immediateRefresh") { [weak self] in
            guard let self else { return }
            Self.logger.error("[BGTask] immediate refresh expired")
            Task { @MainActor in
                ESAppRuntime.shared.store?.cancelBackgroundRefreshIfNeeded()
                self.immediateRefreshLoopTask?.cancel()
                self.immediateRefreshLoopTask = nil
                if self.immediateRefreshTaskID != .invalid {
                    application.endBackgroundTask(self.immediateRefreshTaskID)
                    self.immediateRefreshTaskID = .invalid
                }
            }
        }

        guard immediateRefreshTaskID != .invalid else {
            Self.logger.error("[BGTask] failed to begin immediate background task")
            return
        }

        Self.logger.notice("[BGTask] immediate refresh started")
        immediateRefreshLoopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let store = ESAppRuntime.shared.sharedStore()

            var attempts = 0
            var successAny = false
            let startedAt = Date()

            while !Task.isCancelled {
                attempts += 1
                let success = await store.performBackgroundRefresh()
                successAny = successAny || success

                // Best-effort follow-up refreshes while iOS still grants
                // background task time and thermal transition is active.
                let elapsed = Date().timeIntervalSince(startedAt)
                let shouldContinue = store.shouldRunExtendedBackgroundRefreshLoop() && elapsed < immediateRefreshLoopMaxDuration
                guard shouldContinue else { break }

                Self.logger.notice("[BGTask] immediate refresh follow-up attempt=\(attempts, privacy: .public)")
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }

            let elapsedSeconds = Int(Date().timeIntervalSince(startedAt))
            Self.logger.notice("[BGTask] immediate refresh finished success=\(successAny) attempts=\(attempts, privacy: .public) elapsedSeconds=\(elapsedSeconds, privacy: .public)")
            if self.immediateRefreshTaskID != .invalid {
                application.endBackgroundTask(self.immediateRefreshTaskID)
                self.immediateRefreshTaskID = .invalid
            }
            self.immediateRefreshLoopTask = nil
        }
    }

    private func handleBackgroundTransition(using application: UIApplication, source: String) {
        let interval = ESAppRuntime.shared.store?.recommendedBackgroundRefreshInterval() ?? ESBackgroundRefresh.slowInterval
        Self.logger.notice("[BGTask] background transition source=\(source, privacy: .public) interval=\(Int(interval))")
        Self.scheduleBackgroundRefreshTask(earliestIn: interval)
        runImmediateBackgroundRefresh(application: application)
    }
#endif
}
