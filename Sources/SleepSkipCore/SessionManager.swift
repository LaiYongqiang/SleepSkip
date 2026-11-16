import Combine
import Foundation

public enum StopReason: Equatable, Sendable {
    case manual
    case expired
    case lowBattery(Int)
    case unplugged
    case overheated
    case silent
}

public protocol CaffeinateRunning: AnyObject {
    var isActive: Bool { get }
    func start(mode: GuardMode, timeoutSeconds: Int?, onUnexpectedExit: @escaping () -> Void) throws
    func stop()
}

public protocol BackpackGuarding: AnyObject {
    func enable(completion: @escaping (Result<Void, Error>) -> Void)
    func disable()
    func checkSleepDisabledAsync(completion: @escaping (Bool) -> Void)
    func restoreNormalSleepAsync(completion: @escaping (Result<Void, Error>) -> Void)
}

/// Keeps a closed lid from sleeping the Mac without requiring authorization.
///
/// No read-back is possible: the flag is not published anywhere, so `enable` can only report
/// whether the call was accepted. `checkSleepDisabledAsync` does not apply here — the
/// unprivileged path never touches the system-wide `SleepDisabled` flag.
public protocol ClosedLidGuarding: AnyObject {
    var isEngaged: Bool { get }
    func enable(completion: @escaping (Result<Void, Error>) -> Void)
    func disable()
}

public protocol PowerMonitoring: AnyObject {
    func currentPowerSnapshot() -> PowerSnapshot?
    func start(thresholdPercent: Int, stopOnUnplug: Bool, onEvent: @escaping (PowerEvent) -> Void)
    func stop()
}

public protocol ScreenLocking: AnyObject {
    func lockScreen()
}

public protocol UserNotifying: AnyObject {
    func preparePermissionIfNeeded()
    func send(title: String, body: String)
}

public protocol LoginItemControlling: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

public protocol ThermalMonitoring: AnyObject {
    func isOverheated(cutoff: ThermalCutoff) -> Bool
    func start(cutoff: ThermalCutoff, onOverheated: @escaping () -> Void)
    func stop()
}

public enum CLIInstallStatus: Equatable, Sendable {
    case installed(path: String)
    case notInstalled
    case unavailable
}

public protocol CLIInstalling: AnyObject {
    func currentStatus() -> CLIInstallStatus
    func install(completion: @escaping (Result<String, Error>) -> Void)
}

public final class SessionManager: ObservableObject {
    @Published public var config: SessionConfig
    @Published public var isRunning: Bool = false
    @Published public var isAuthorizing: Bool = false
    /// Identifies the in-flight authorization so a stale timeout cannot cancel a newer attempt.
    private var activeAuthorizationToken: UUID?
    @Published public var activeMode: GuardMode = .background
    @Published public var activeClosedLid: Bool = false
    @Published public var isIndefinite: Bool = false
    @Published public var initialMinutes: Double = 240
    @Published public var endDate: Date? = nil
    @Published public var remainingSeconds: Int = 0
    @Published public var errorMessage: String? = nil
    @Published public var staleSleepDisabled: Bool = false
    @Published public var showSettings: Bool = false
    @Published public var showAgentSourcesConfig: Bool = false
    @Published public var showAdvancedSettings: Bool = false
    @Published public var showHistory: Bool = false
    @Published public var showCustomInput: Bool = false
    @Published public var customMinutesText: String = "90"
    @Published public var launchAtLogin: Bool = false
    @Published public var externalCLI: ExternalCLISession? = nil

    /// True while a detected agent is holding the assertion on the user's behalf.
    @Published public var isFollowingAgents: Bool = false
    /// Agents currently driving the automatic session, for display.
    @Published public var followingAgents: [String] = []
    /// Target release time for the current idle grace period, nil while agents are actively writing.
    @Published public var autoFollowGraceEndDate: Date? = nil
    /// Seconds remaining until the grace period releases, updated while the popover is open.
    @Published public var autoFollowGraceRemainingSeconds: Int = 0
    /// True once an automatic session hit its hard ceiling; the next detection starts fresh.
    @Published public var autoFollowLimitReached: Bool = false
    /// Set after the user stops a session while agents are still writing, so the Mac does not
    /// immediately wake itself again. Cleared once all agents have gone quiet.
    private var autoFollowSuppressed = false
    private var lastAgentActivityState: AgentActivityState = .inactive

    /// First-run explanation of what auto-follow watches. Shown once, then never again.
    @Published public var showAutoFollowNotice: Bool = false
    /// Directories that actually exist on this machine, for display. Empty means the switch has
    /// nothing to watch.
    @Published public var agentSources: [AgentSource] = []
    /// Recent completed sessions, capped at 10 entries and persisted only when a session ends.
    @Published public var history: [SessionHistoryEntry] = []
    @Published public var cliInstallStatus: CLIInstallStatus = .unavailable
    @Published public var isInstallingCLI: Bool = false
    @Published public var claudeHookConnected: Bool = false

    public struct HookLease: Equatable, Sendable {
        public let sessionID: String
        public let agent: String
        public let startedAt: Date
    }

    private var activeHookSessions: [String: HookLease] = [:]

    private var activeSessionStartDate: Date? = nil
    private var activeSessionTrigger: SessionTrigger = .manual
    private var activeSessionAgents: [String] = []
    private var nextManualTrigger: SessionTrigger = .manual

    private let store: PreferencesStore
    private let caffeinateRunner: CaffeinateRunning
    private let backpackGuard: BackpackGuarding
    /// No-authorization lid guard, used when `config.closedLidStrategy == .unprivileged`.
    private let unprivilegedLidGuard: ClosedLidGuarding?
    private let powerMonitor: PowerMonitoring
    private let thermalMonitor: ThermalMonitoring?
    private let screenLocker: ScreenLocking
    private let notifier: UserNotifying
    private let loginItem: LoginItemControlling
    private let cliInstaller: CLIInstalling?
    private let claudeHookController: ClaudeHookControlling?
    private let runtimeStateURL: URL?
    private let runtimePID: Int32
    private let nowProvider: () -> Date
    private let authorizationScheduler: (TimeInterval, @escaping () -> Void) -> Void
    /// Exposed so the host can hand it to the FSEvents monitor.
    public let agentTracker: AgentActivityTracker

    public var onStateChange: ((_ active: Bool, _ closedLid: Bool) -> Void)?
    public var onRequestClosePopover: (() -> Void)?
    /// Called when auto-follow starts or stops so the host can start/stop the FSEvents monitor.
    public var onAutoFollowToggled: ((_ enabled: Bool) -> Void)?
    /// Called when enabled agent sources or custom folders change while auto-follow may be active.
    public var onAgentSourcesConfigChanged: (() -> Void)?
    /// Called when the global shortcut preference changes so the host can register/unregister it.
    public var onGlobalShortcutToggled: ((_ enabled: Bool) -> Void)?
    /// Called when the first-run notice is dismissed so the host can persist that fact.
    public var onAutoFollowNoticeDismissed: (() -> Void)?

    public var l10n: L10n {
        L10n(language: config.language)
    }

    public var isEffectivelyActive: Bool {
        isRunning || externalCLI != nil
    }

    public var isAutoFollowEnabled: Bool {
        config.autoFollowAgents
    }

    /// Surfaces the one-time notice. Called at launch when the setting is on and the user has
    /// not dismissed it yet.
    public func presentAutoFollowNoticeIfNeeded(hasDismissed: Bool) {
        showAutoFollowNotice = config.autoFollowAgents && !hasDismissed
    }

    public func setAgentSources(_ sources: [AgentSource]) {
        agentSources = sources
    }

    public func dismissAutoFollowNotice() {
        showAutoFollowNotice = false
        onAutoFollowNoticeDismissed?()
    }

    /// Called when the panel closes. A notice the user has already seen should not reappear.
    public func retireAutoFollowNoticeOnPanelClose() {
        guard showAutoFollowNotice else { return }
        dismissAutoFollowNotice()
    }

    /// Starts or stops watching for agent activity. The monitor itself is owned by the host
    /// so the core stays free of FSEvents; this only flips the preference and notifies.
    public func setAutoFollowEnabled(_ enabled: Bool) {
        guard config.autoFollowAgents != enabled else { return }
        config.autoFollowAgents = enabled
        autoFollowSuppressed = false
        persistConfig()
        if !enabled {
            lastAgentActivityState = .inactive
            if !hasActiveHookSessions { endAutoFollow() }
            else if isFollowingAgents {
                followingAgents = mergedFollowingAgents()
                autoFollowGraceEndDate = nil
            }
            showAutoFollowNotice = false
        }
        onAutoFollowToggled?(enabled)
        notifyStateTransition()
    }

    public func isBuiltInAgentEnabled(_ id: String) -> Bool {
        !config.disabledAgentSourceIDs.contains(id)
    }

    public func setBuiltInAgentEnabled(_ id: String, enabled: Bool) {
        var disabled = Set(config.disabledAgentSourceIDs)
        if enabled {
            disabled.remove(id)
        } else {
            disabled.insert(id)
        }
        config.disabledAgentSourceIDs = disabled.sorted()
        persistConfig()
        onAgentSourcesConfigChanged?()
    }

    public func addCustomAgentPath(_ rawPath: String) {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        guard !standardized.isEmpty, !config.customAgentPaths.contains(standardized) else { return }
        config.customAgentPaths.append(standardized)
        persistConfig()
        onAgentSourcesConfigChanged?()
    }

    public func removeCustomAgentPath(_ path: String) {
        config.customAgentPaths.removeAll { $0 == path }
        persistConfig()
        onAgentSourcesConfigChanged?()
    }

    public func setGlobalShortcutEnabled(_ enabled: Bool) {
        guard config.globalShortcutEnabled != enabled else { return }
        config.globalShortcutEnabled = enabled
        persistConfig()
        onGlobalShortcutToggled?(enabled)
    }

    /// Called by the monitor on transitions and writes; repeated display values are deduplicated.
    public func handleAgentActivity(_ state: AgentActivityState) {
        let previousActivity = latestDirectoryActivity(in: lastAgentActivityState)
        lastAgentActivityState = state
        guard config.autoFollowAgents else { return }

        // Timers may be delayed while the Mac sleeps. A fresh write after a full quiet gap
        // must re-arm even if the monitor never delivered the intermediate inactive state.
        if autoFollowSuppressed {
            guard !hasActiveHookSessions else { return }
            if state == .inactive {
                autoFollowSuppressed = false
                return
            }
            guard let previousActivity, let currentActivity = latestDirectoryActivity(in: state),
                  currentActivity.timeIntervalSince(previousActivity)
                    >= agentTracker.currentPolicy.activityWindow + agentTracker.currentPolicy.gracePeriod else { return }
            autoFollowSuppressed = false
        }

        // A manual session always wins; auto-follow never overrides it.
        //
        // The check must exclude sessions auto-follow started itself. `beginAutoFollow` sets
        // `isRunning`, so guarding on `isRunning` alone made the first `.active` block every
        // later transition — including `.inactive` — leaving `endAutoFollow` unreachable and the
        // assertion held for the full configured duration after the agents had gone quiet.
        guard !isRunning || isFollowingAgents else { return }

        if hasActiveHookSessions || agentTracker.shouldHoldAssertion(for: state) {
            let previousAgents = followingAgents
            switch state {
            case .active(let agents, _):
                let merged = mergedFollowingAgents()
                let nextAgents = merged.isEmpty ? agents.map(AgentSource.displayName(forIdentifier:)) : merged
                if followingAgents != nextAgents { followingAgents = nextAgents }
                if !nextAgents.isEmpty { activeSessionAgents = nextAgents }
                if autoFollowGraceEndDate != nil { autoFollowGraceEndDate = nil }
            case .grace(let since):
                let graceEnd = hasActiveHookSessions ? nil : since.addingTimeInterval(agentTracker.currentPolicy.gracePeriod)
                if autoFollowGraceEndDate != graceEnd { autoFollowGraceEndDate = graceEnd }
            case .inactive:
                if hasActiveHookSessions {
                    let merged = mergedFollowingAgents()
                    if followingAgents != merged { followingAgents = merged }
                    if autoFollowGraceEndDate != nil { autoFollowGraceEndDate = nil }
                }
            }
            if !isFollowingAgents {
                beginAutoFollow()
            } else {
                if followingAgents != previousAgents {
                    writeRuntimeStateSnapshot()
                }
                refreshDisplayTick()
            }
        } else if isFollowingAgents {
            endAutoFollow()
        }
    }

    private func latestDirectoryActivity(in state: AgentActivityState) -> Date? {
        switch state {
        case .active(_, let lastActivity): return lastActivity
        case .grace(let since): return since.addingTimeInterval(-agentTracker.currentPolicy.activityWindow)
        case .inactive: return nil
        }
    }

    private var directoryActivityStillHolding: Bool {
        guard let lastActivity = latestDirectoryActivity(in: lastAgentActivityState) else { return false }
        return nowProvider().timeIntervalSince(lastActivity)
            < agentTracker.currentPolicy.activityWindow + agentTracker.currentPolicy.gracePeriod
    }

    private func beginAutoFollow() {
        guard !isRunning, !isAuthorizing, passesPowerAndThermalPreflight() else { return }
        notifier.preparePermissionIfNeeded()
        // Auto-follow is background-only, never enables closed-lid mode, and is bounded by the
        // agent policy's hard ceiling rather than the user's manual timer preset.
        let ceilingSeconds = max(1, Int(agentTracker.currentPolicy.maxAutoSessionDuration.rounded()))
        do {
            try caffeinateRunner.start(mode: .background, timeoutSeconds: ceilingSeconds + 30) { [weak self] in
                self?.handleCaffeinateExited()
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        agentTracker.restartSessionWindow()
        activeMode = .background
        activeClosedLid = false
        isIndefinite = false
        initialMinutes = Double(ceilingSeconds) / 60.0
        let now = nowProvider()
        activeSessionStartDate = now
        activeSessionTrigger = .autoFollow
        activeSessionAgents = followingAgents
        endDate = now.addingTimeInterval(TimeInterval(ceilingSeconds))
        isFollowingAgents = true
        autoFollowLimitReached = false
        isRunning = true
        refreshDisplayTick()
        startPowerWatch()
        startThermalWatch()
        notifyStateTransition()
    }

    private func endAutoFollow(stopReasonCode: String = "autoFollowQuiet") {
        guard isFollowingAgents else { return }
        let wasRunning = isRunning
        if wasRunning {
            recordCompletedSession(stopReasonCode: stopReasonCode)
        }
        isFollowingAgents = false
        followingAgents = []
        autoFollowGraceEndDate = nil
        autoFollowGraceRemainingSeconds = 0
        if wasRunning, isAuthorizing {
            // Quiet ends the old automatic assertion, not the explicit manual request whose
            // authorization is still pending. Keep its guard/token and safety watches alive.
            caffeinateRunner.stop()
            isRunning = false
            activeClosedLid = false
            activeSessionAgents = []
            endDate = nil
            remainingSeconds = 0
            notifyStateTransition()
        } else if wasRunning {
            stopSession(reason: .silent)
        } else {
            notifyStateTransition()
        }
    }

    /// The hard ceiling was hit: release now and require a fresh detection before holding again.
    public func handleAutoFollowLimitReached() {
        guard isFollowingAgents else { return }
        autoFollowLimitReached = true
        // A still-writing agent must stay released until a real quiet period or bounded hook
        // lease expiry. Repeated writes cannot turn the ceiling into a brief release/restart.
        autoFollowSuppressed = true
        endAutoFollow(stopReasonCode: "autoFollowLimit")
        notifier.send(title: l10n.notifAutoFollowLimitTitle, body: l10n.notifAutoFollowLimitBody)
    }

    public func resetAutoFollowLimit() {
        autoFollowLimitReached = false
        if !hasActiveHookSessions, agentTracker.evaluate() == .inactive {
            autoFollowSuppressed = false
        }
    }

    /// Starts or refreshes an explicit hook lease (e.g., from Claude Code `UserPromptSubmit`).
    public func handleHookStart(sessionID: String, agent: String) {
        let key = normalizedHookSessionID(sessionID, agent: agent)
        let displayAgent = AgentSource.displayName(forIdentifier: agent)
        activeHookSessions[key] = HookLease(sessionID: sessionID, agent: displayAgent, startedAt: nowProvider())

        // Manual sessions always win; track the lease silently until manual ends.
        guard !isRunning || isFollowingAgents else { return }

        guard !autoFollowSuppressed else { return }
        let hookAgents = mergedFollowingAgents()
        followingAgents = hookAgents
        if !hookAgents.isEmpty {
            activeSessionAgents = hookAgents
        }
        autoFollowGraceEndDate = nil
        autoFollowGraceRemainingSeconds = 0

        if !isFollowingAgents {
            beginAutoFollow()
        } else {
            writeRuntimeStateSnapshot()
            refreshDisplayTick()
        }
    }

    /// Releases an explicit hook lease (e.g., from Claude Code `Stop` or a tracked PID exit).
    public func handleHookStop(sessionID: String, agent: String = "claude-code", reasonCode: String = "hookStop") {
        let key = normalizedHookSessionID(sessionID, agent: agent)
        guard activeHookSessions.removeValue(forKey: key) != nil else { return }

        let displayAgent = AgentSource.displayName(forIdentifier: agent)
        if !activeHookSessions.values.contains(where: { $0.agent == displayAgent }) {
            agentTracker.removeActivity(sourceID: agent)
        }
        reconcileHookSourcesAfterRelease(reasonCode: reasonCode)
    }

    private func reconcileHookSourcesAfterRelease(reasonCode: String) {
        let trackerState = config.autoFollowAgents ? agentTracker.evaluate() : .inactive
        lastAgentActivityState = trackerState
        if !hasActiveHookSessions, !trackerState.isHolding {
            autoFollowSuppressed = false
            if isFollowingAgents { endAutoFollow(stopReasonCode: reasonCode) }
        } else if isFollowingAgents {
            let remainingAgents = mergedFollowingAgents()
            followingAgents = remainingAgents
            activeSessionAgents = remainingAgents
            if !hasActiveHookSessions, case .grace(let since) = trackerState {
                autoFollowGraceEndDate = since.addingTimeInterval(agentTracker.currentPolicy.gracePeriod)
            } else {
                autoFollowGraceEndDate = nil
            }
            writeRuntimeStateSnapshot()
            refreshDisplayTick()
        }
    }

    public var hasActiveHookSessions: Bool {
        !activeHookSessions.isEmpty
    }

    /// A missing Stop hook must not leave a suppressed lease alive forever. The host schedules
    /// this earliest per-lease deadline independently of whether an assertion is currently held.
    public var nextHookLeaseExpirationDate: Date? {
        activeHookSessions.values.map {
            $0.startedAt.addingTimeInterval(max(1, agentTracker.currentPolicy.maxAutoSessionDuration))
        }.min()
    }

    @discardableResult
    public func expireHookLeases() -> [HookLease] {
        let now = nowProvider()
        let duration = max(1, agentTracker.currentPolicy.maxAutoSessionDuration)
        let expired = activeHookSessions.values.filter {
            now.timeIntervalSince($0.startedAt) >= duration
        }.sorted { $0.startedAt < $1.startedAt }
        for lease in expired {
            let key = normalizedHookSessionID(lease.sessionID, agent: lease.agent)
            activeHookSessions.removeValue(forKey: key)
        }
        // Expiry proves only that this hook lease elapsed. A transcript may still be busy;
        // unlike an explicit Stop/PID exit, this must not manufacture a quiet source boundary.
        if !expired.isEmpty { reconcileHookSourcesAfterRelease(reasonCode: "hookLeaseExpired") }
        return expired
    }

    private func normalizedHookSessionID(_ raw: String, agent: String) -> String {
        let session = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let agentKey = AgentSource.displayName(forIdentifier: agent).lowercased()
        // Length-prefixing avoids collisions even when a caller's IDs contain separators.
        return "\(agentKey.utf8.count):\(agentKey):\(session.isEmpty ? "default" : session)"
    }

    private func mergedFollowingAgents() -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for lease in activeHookSessions.values.sorted(by: { $0.startedAt < $1.startedAt }) {
            if seen.insert(lease.agent).inserted {
                result.append(lease.agent)
            }
        }
        if config.autoFollowAgents {
            for sourceID in agentTracker.holdingSourceIDs {
                let name = AgentSource.displayName(forIdentifier: sourceID)
                if seen.insert(name).inserted { result.append(name) }
            }
        }
        return result
    }

    public init(
        store: PreferencesStore = PreferencesStore(),
        caffeinateRunner: CaffeinateRunning,
        backpackGuard: BackpackGuarding,
        unprivilegedLidGuard: ClosedLidGuarding? = nil,
        powerMonitor: PowerMonitoring,
        thermalMonitor: ThermalMonitoring? = nil,
        screenLocker: ScreenLocking,
        notifier: UserNotifying,
        loginItem: LoginItemControlling,
        cliInstaller: CLIInstalling? = nil,
        claudeHookController: ClaudeHookControlling? = nil,
        runtimeStateURL: URL? = nil,
        runtimePID: Int32 = ProcessInfo.processInfo.processIdentifier,
        nowProvider: @escaping () -> Date = { Date() },
        agentPolicy: AgentActivityPolicy = .default,
        checkStaleSleepOnInit: Bool = true,
        authorizationScheduler: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    ) {
        self.store = store
        self.caffeinateRunner = caffeinateRunner
        self.backpackGuard = backpackGuard
        self.unprivilegedLidGuard = unprivilegedLidGuard
        self.powerMonitor = powerMonitor
        self.thermalMonitor = thermalMonitor
        self.screenLocker = screenLocker
        self.notifier = notifier
        self.loginItem = loginItem
        self.cliInstaller = cliInstaller
        self.claudeHookController = claudeHookController
        self.runtimeStateURL = runtimeStateURL
        self.runtimePID = runtimePID
        self.nowProvider = nowProvider
        self.authorizationScheduler = authorizationScheduler
        self.agentTracker = AgentActivityTracker(policy: agentPolicy, nowProvider: nowProvider)

        let loaded = store.load()
        self.config = loaded
        self.customMinutesText = loaded.customMinutes == loaded.customMinutes.rounded()
            ? "\(Int(loaded.customMinutes))"
            : String(format: "%.1f", loaded.customMinutes)
        self.launchAtLogin = loginItem.isEnabled
        self.history = store.loadHistory()
        self.cliInstallStatus = cliInstaller?.currentStatus() ?? .unavailable
        self.claudeHookConnected = claudeHookController?.isConnected ?? false
        writeRuntimeStateSnapshot()

        if checkStaleSleepOnInit {
            backpackGuard.checkSleepDisabledAsync { [weak self] disabled in
                guard let self, !self.isRunning else { return }
                self.staleSleepDisabled = disabled
            }
        }
    }

    public func persistConfig() {
        store.save(config)
    }

    public func selectMode(_ mode: GuardMode) {
        config.mode = mode
        persistConfig()
    }

    public func selectDuration(_ minutes: Double) {
        config.durationMinutes = minutes
        showCustomInput = false
        persistConfig()
    }

    public func applyCustomDuration() {
        let trimmed = customMinutesText.trimmingCharacters(in: .whitespacesAndNewlines)
        // `Double("inf")` and `Double("1e999")` parse to infinity; sanitize before persisting so a
        // bad value can never reach Int(_:) in the countdown or the caffeinate timeout.
        guard let parsed = Double(trimmed), let val = CommandBuilder.sanitizeMinutes(parsed) else {
            errorMessage = l10n.invalidDurationError(CommandBuilder.maxDurationMinutes)
            return
        }
        config.customMinutes = val
        config.durationMinutes = val
        showCustomInput = false
        errorMessage = nil
        persistConfig()
    }

    public func setLockOnStart(_ enabled: Bool) {
        config.lockOnStart = enabled
        persistConfig()
    }

    public func setAllowClosedLid(_ enabled: Bool) {
        config.allowClosedLid = enabled
        persistConfig()
    }

    /// Switches how lid-close sleep is suppressed. Takes effect on the next session; an active
    /// session keeps whatever it started with, since swapping mechanisms mid-flight would leave
    /// one of them disengaged without the user asking.
    public func setClosedLidStrategy(_ strategy: ClosedLidStrategy) {
        config.closedLidStrategy = strategy
        persistConfig()
    }

    public func setBatteryThreshold(_ percent: Int) {
        config.batteryThresholdPercent = percent
        persistConfig()
        if isRunning || isAuthorizing {
            startPowerWatch()
        }
    }

    public func setStopOnUnplug(_ enabled: Bool) {
        config.stopOnUnplug = enabled
        persistConfig()
        if isRunning || isAuthorizing {
            startPowerWatch()
        }
    }

    public func refreshClaudeHookStatus() {
        claudeHookConnected = claudeHookController?.isConnected ?? false
    }

    public func toggleClaudeHookConnection() {
        guard let claudeHookController else { return }
        errorMessage = nil
        do {
            if claudeHookConnected {
                try claudeHookController.disconnect()
            } else {
                try claudeHookController.connect()
            }
            claudeHookConnected = claudeHookController.isConnected
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func setThermalCutoff(_ cutoff: ThermalCutoff) {
        config.thermalCutoff = cutoff
        persistConfig()
        if isRunning || isAuthorizing {
            if thermalMonitor?.isOverheated(cutoff: cutoff) == true {
                stopSession(reason: .overheated)
            } else {
                startThermalWatch()
            }
        }
    }

    public func refreshCLIInstallStatus() {
        cliInstallStatus = cliInstaller?.currentStatus() ?? .unavailable
    }

    public func installCLICommand() {
        guard let cliInstaller, !isInstallingCLI else { return }
        isInstallingCLI = true
        errorMessage = nil
        cliInstaller.install { [weak self] result in
            guard let self else { return }
            self.isInstallingCLI = false
            switch result {
            case .success(let path):
                self.cliInstallStatus = .installed(path: path)
            case .failure(let error):
                self.errorMessage = error.localizedDescription
                self.refreshCLIInstallStatus()
            }
        }
    }

    public func clearHistory() {
        history = []
        store.saveHistory([])
    }

    public func setLanguage(_ language: AppLanguage) {
        config.language = language
        persistConfig()
        notifyStateTransition()
    }

    public func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
            launchAtLogin = loginItem.isEnabled
            errorMessage = nil
        } catch {
            launchAtLogin = loginItem.isEnabled
            errorMessage = error.localizedDescription
        }
    }

    public func refreshDisplayTick() {
        guard isRunning else { return }
        let now = nowProvider()
        let graceRemaining: Int
        if isFollowingAgents, let graceEnd = autoFollowGraceEndDate {
            graceRemaining = max(0, Int(graceEnd.timeIntervalSince(now).rounded(.down)))
        } else {
            graceRemaining = 0
        }
        if autoFollowGraceRemainingSeconds != graceRemaining { autoFollowGraceRemainingSeconds = graceRemaining }
        if isIndefinite {
            if remainingSeconds != 0 { remainingSeconds = 0 }
            return
        }
        guard let endDate else { return }
        if now >= endDate {
            if isFollowingAgents { handleAutoFollowLimitReached() }
            else { stopSession(reason: .expired) }
            return
        }
        let remaining = max(0, Int(endDate.timeIntervalSince(now).rounded(.down)))
        if remainingSeconds != remaining { remainingSeconds = remaining }
    }

    public func reconcileOnWakeOrShow() {
        guard isRunning else { return }
        // Evaluate the automatic deadline before handling a process that timed out while asleep.
        refreshDisplayTick()
        guard isRunning else { return }
        if !caffeinateRunner.isActive { stopSession(reason: .expired) }
    }

    public func setExternalCLISession(_ session: ExternalCLISession?) {
        externalCLI = session
        notifyStateTransition()
    }

    public func startConfiguredSession() {
        guard !isAuthorizing else { return }
        errorMessage = nil
        persistConfig()

        guard passesPowerAndThermalPreflight() else { return }

        let targetMode = config.mode
        let targetMinutes = config.durationMinutes
        let wantClosedLid = config.effectiveAllowClosedLid
        let wantLock = config.effectiveLockOnStart

        if targetMinutes > 0 || config.batteryThresholdPercent > 0 || config.stopOnUnplug || config.thermalCutoff != .off {
            notifier.preparePermissionIfNeeded()
        }

        if wantClosedLid {
            switch config.closedLidStrategy {
            case .unprivileged:
                startUnprivilegedLidGuard(
                    mode: targetMode,
                    minutes: targetMinutes,
                    lockImmediately: wantLock
                )
            case .privileged:
                startPrivilegedLidGuard(
                    mode: targetMode,
                    minutes: targetMinutes,
                    lockImmediately: wantLock
                )
            }
        } else {
            unprivilegedLidGuard?.disable()
            backpackGuard.disable()
            launchCaffeinate(mode: targetMode, minutes: targetMinutes, closedLid: false, lockImmediately: wantLock)
        }
    }

    private func passesPowerAndThermalPreflight() -> Bool {
        if let snapshot = powerMonitor.currentPowerSnapshot(), snapshot.onBattery {
            if config.stopOnUnplug {
                errorMessage = l10n.unpluggedBlockedError
                return false
            }
            if config.batteryThresholdPercent > 0,
               let pct = snapshot.percentage,
               pct <= config.batteryThresholdPercent {
                errorMessage = l10n.lowBatteryBlockedError(current: pct, threshold: config.batteryThresholdPercent)
                return false
            }
        }

        if thermalMonitor?.isOverheated(cutoff: config.thermalCutoff) == true {
            errorMessage = l10n.overheatedBlockedError
            return false
        }

        return true
    }

    /// No authorization: set the clamshell flag and keep re-setting it.
    private func startUnprivilegedLidGuard(mode: GuardMode, minutes: Double, lockImmediately: Bool) {
        guard let unprivilegedLidGuard else {
            errorMessage = l10n.unprivilegedLidUnavailable
            return
        }
        unprivilegedLidGuard.enable { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.launchCaffeinate(mode: mode, minutes: minutes, closedLid: true, lockImmediately: lockImmediately)
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Admin authorization via `pmset -a disablesleep 1`. Survives a power-source change, which
    /// the unprivileged path does not.
    private func startPrivilegedLidGuard(mode: GuardMode, minutes: Double, lockImmediately: Bool) {
        unprivilegedLidGuard?.disable()
        isAuthorizing = true
        // An authorization dialog that is dismissed without a result, or an AppleScript call
        // that never returns, used to leave the button spinning forever with no way out.
        let authorizationToken = UUID()
        activeAuthorizationToken = authorizationToken
        authorizationScheduler(120) { [weak self] in
            guard let self, self.isAuthorizing, self.activeAuthorizationToken == authorizationToken else { return }
            self.isAuthorizing = false
            self.activeAuthorizationToken = nil
            self.backpackGuard.disable()
            self.stopIdleSafetyWatches()
            self.errorMessage = self.l10n.authorizationTimedOut
        }
        backpackGuard.enable { [weak self] result in
            guard let self else { return }
            guard self.activeAuthorizationToken == authorizationToken else {
                // The system guard also invalidates attempts internally. This cleanup covers
                // simple guard implementations without cancelling a newer authorization/session.
                if case .success = result, !self.isAuthorizing, !self.activeClosedLid {
                    self.backpackGuard.disable()
                }
                return
            }
            self.activeAuthorizationToken = nil
            self.isAuthorizing = false
            switch result {
            case .success:
                self.staleSleepDisabled = false
                self.launchCaffeinate(mode: mode, minutes: minutes, closedLid: true, lockImmediately: lockImmediately)
            case .failure(let error):
                self.stopIdleSafetyWatches()
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func launchCaffeinate(mode: GuardMode, minutes: Double, closedLid: Bool, lockImmediately: Bool) {
        // Authorization can take up to two minutes; power and thermal conditions may have
        // changed since the request. Reject before replacing an assertion or locking the screen.
        guard passesPowerAndThermalPreflight() else {
            if closedLid {
                backpackGuard.disable()
                unprivilegedLidGuard?.disable()
            }
            stopIdleSafetyWatches()
            return
        }
        let timeoutSec = CommandBuilder.timeoutSeconds(forMinutes: minutes)

        do {
            try caffeinateRunner.start(mode: mode, timeoutSeconds: timeoutSec) { [weak self] in
                self?.handleCaffeinateExited()
            }
        } catch {
            if closedLid {
                backpackGuard.disable()
                unprivilegedLidGuard?.disable()
            }
            stopIdleSafetyWatches()
            errorMessage = error.localizedDescription
            return
        }

        if isFollowingAgents {
            recordCompletedSession(stopReasonCode: "manualPromotion")
            isFollowingAgents = false
            followingAgents = []
            autoFollowGraceEndDate = nil
            autoFollowGraceRemainingSeconds = 0
        }
        activeMode = mode
        activeClosedLid = closedLid
        isIndefinite = (timeoutSec == nil)
        initialMinutes = minutes
        let now = nowProvider()
        activeSessionStartDate = now
        activeSessionTrigger = nextManualTrigger
        nextManualTrigger = .manual
        activeSessionAgents = []
        endDate = timeoutSec.map { now.addingTimeInterval(TimeInterval($0)) }
        isRunning = true
        showCustomInput = false
        showSettings = false
        refreshDisplayTick()
        startPowerWatch()
        startThermalWatch()

        notifyStateTransition()

        if lockImmediately {
            onRequestClosePopover?()
            screenLocker.lockScreen()
        }
    }

    public func switchRunningMode(to newMode: GuardMode) {
        guard isRunning, newMode != activeMode else { return }
        errorMessage = nil

        let promotingFromAutoFollow = isFollowingAgents
        let remainingTimeout: Int?
        if promotingFromAutoFollow {
            remainingTimeout = CommandBuilder.timeoutSeconds(forMinutes: config.durationMinutes)
        } else if isIndefinite {
            remainingTimeout = nil
        } else if let endDate {
            remainingTimeout = max(1, Int(endDate.timeIntervalSince(nowProvider()).rounded()))
        } else {
            remainingTimeout = nil
        }

        do {
            try caffeinateRunner.start(mode: newMode, timeoutSeconds: remainingTimeout) { [weak self] in
                self?.handleCaffeinateExited()
            }
            activeMode = newMode
            if newMode == .keepDisplay, activeClosedLid {
                backpackGuard.disable()
                unprivilegedLidGuard?.disable()
                activeClosedLid = false
            }
            config.mode = newMode
            persistConfig()
            if promotingFromAutoFollow {
                isFollowingAgents = false
                followingAgents = []
                activeSessionTrigger = .manual
                activeSessionAgents = []
                autoFollowGraceEndDate = nil
                autoFollowGraceRemainingSeconds = 0
                isIndefinite = (remainingTimeout == nil)
                initialMinutes = config.durationMinutes
                endDate = remainingTimeout.map { nowProvider().addingTimeInterval(TimeInterval($0)) }
                refreshDisplayTick()
            }
            notifyStateTransition()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func extendSession(byMinutes addMinutes: Double = 30) {
        guard isRunning, !isIndefinite else { return }
        errorMessage = nil

        let currentLeft = max(0, endDate?.timeIntervalSince(nowProvider()) ?? 0)
        let newTotalSeconds = max(1, Int((currentLeft + addMinutes * 60.0).rounded()))
        let newEndDate = nowProvider().addingTimeInterval(TimeInterval(newTotalSeconds))

        do {
            try caffeinateRunner.start(mode: activeMode, timeoutSeconds: newTotalSeconds) { [weak self] in
                self?.handleCaffeinateExited()
            }
            endDate = newEndDate
            initialMinutes += addMinutes
            refreshDisplayTick()
            notifyStateTransition()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func stopSession(reason: StopReason = .manual) {
        if isRunning {
            recordCompletedSession(stopReasonCode: stopReasonCode(for: reason))
        }
        powerMonitor.stop()
        thermalMonitor?.stop()
        caffeinateRunner.stop()
        backpackGuard.disable()
        unprivilegedLidGuard?.disable()

        // Invalidate any in-flight authorization. Its completion checks the token, so without
        // this a session the user explicitly stopped would be launched anyway when Touch ID
        // returned a few seconds later.
        activeAuthorizationToken = nil
        isAuthorizing = false

        // A user-initiated stop while agents are still writing should stay stopped; only a fresh
        // quiet period re-arms auto-follow.
        if reason == .manual {
            autoFollowSuppressed = hasActiveHookSessions
                || (config.autoFollowAgents && (directoryActivityStillHolding || agentTracker.evaluate().isHolding))
        }
        isFollowingAgents = false
        followingAgents = []
        autoFollowGraceEndDate = nil
        autoFollowGraceRemainingSeconds = 0
        isRunning = false
        activeClosedLid = false
        activeSessionStartDate = nil
        activeSessionAgents = []
        endDate = nil
        remainingSeconds = 0
        notifyStateTransition()

        switch reason {
        case .manual, .silent:
            break
        case .expired:
            notifier.send(title: l10n.notifStoppedTitle, body: l10n.notifExpiredBody)
        case .lowBattery(let pct):
            notifier.send(title: l10n.notifLowBatteryTitle, body: l10n.notifLowBatteryBody(pct))
        case .unplugged:
            notifier.send(title: l10n.notifUnpluggedTitle, body: l10n.notifUnpluggedBody)
        case .overheated:
            notifier.send(title: l10n.notifOverheatedTitle, body: l10n.notifOverheatedBody)
        }
    }

    public func applyURLCommand(_ command: URLCommand) {
        switch command {
        case .start(let mode, let minutes, let lockOnStart, let allowClosedLid):
            if let mode { config.mode = mode }
            if let minutes { config.durationMinutes = minutes }
            if let lockOnStart { config.lockOnStart = lockOnStart }
            if let allowClosedLid { config.allowClosedLid = allowClosedLid }
            persistConfig()
            if !isRunning || isFollowingAgents {
                nextManualTrigger = .url
                startConfiguredSession()
            } else if let mode, mode != activeMode {
                switchRunningMode(to: mode)
            }
        case .stop:
            if isRunning || isAuthorizing {
                stopSession(reason: .manual)
            }
        case .toggle:
            if isRunning || isAuthorizing {
                stopSession(reason: .manual)
            } else {
                nextManualTrigger = .url
                startConfiguredSession()
            }
        case .lock:
            onRequestClosePopover?()
            screenLocker.lockScreen()
        case .open:
            break
        }
    }

    /// Re-reads `SleepDisabled` so a guard left behind by a previous run is reported promptly.
    public func refreshStaleSleepState() {
        guard !isRunning else { return }
        backpackGuard.checkSleepDisabledAsync { [weak self] disabled in
            guard let self, !self.isRunning else { return }
            self.staleSleepDisabled = disabled
        }
    }

    public func restoreStaleSleepDisabled() {
        backpackGuard.restoreNormalSleepAsync { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.staleSleepDisabled = false
                self.errorMessage = nil
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func handleCaffeinateExited() {
        guard isRunning else { return }
        if isFollowingAgents, let endDate, nowProvider() >= endDate {
            handleAutoFollowLimitReached()
        } else {
            stopSession(reason: .expired)
        }
    }

    private func stopIdleSafetyWatches() {
        guard !isRunning, !isAuthorizing else { return }
        powerMonitor.stop()
        thermalMonitor?.stop()
    }

    private func startPowerWatch() {
        powerMonitor.start(
            thresholdPercent: config.batteryThresholdPercent,
            stopOnUnplug: config.stopOnUnplug
        ) { [weak self] event in
            guard let self, self.isRunning || self.isAuthorizing else { return }
            switch event {
            case .lowBattery(let pct):
                self.stopSession(reason: .lowBattery(pct))
            case .unplugged:
                self.stopSession(reason: .unplugged)
            }
        }
    }

    private func startThermalWatch() {
        thermalMonitor?.start(cutoff: config.thermalCutoff) { [weak self] in
            guard let self, self.isRunning || self.isAuthorizing else { return }
            self.stopSession(reason: .overheated)
        }
    }

    private func stopReasonCode(for reason: StopReason) -> String {
        switch reason {
        case .manual: return "manual"
        case .expired: return "expired"
        case .lowBattery(let pct): return "lowBattery:\(pct)"
        case .unplugged: return "unplugged"
        case .overheated: return "overheated"
        case .silent: return "silent"
        }
    }

    private func recordCompletedSession(stopReasonCode: String) {
        guard let startedAt = activeSessionStartDate else { return }
        activeSessionStartDate = nil
        let endedAt = nowProvider()
        let entry = SessionHistoryEntry(
            trigger: activeSessionTrigger,
            mode: activeMode,
            closedLid: activeClosedLid,
            agents: activeSessionAgents,
            startedAt: startedAt,
            endedAt: endedAt,
            stopReasonCode: stopReasonCode
        )
        history.insert(entry, at: 0)
        if history.count > 10 {
            history = Array(history.prefix(10))
        }
        store.saveHistory(history)
    }

    public func clearRuntimeStateSnapshot() {
        guard let runtimeStateURL else { return }
        RuntimeStateSnapshot.remove(at: runtimeStateURL)
    }

    private func notifyStateTransition() {
        writeRuntimeStateSnapshot()
        onStateChange?(isEffectivelyActive, activeClosedLid)
    }

    private func writeRuntimeStateSnapshot() {
        guard let runtimeStateURL else { return }
        let snapshot = RuntimeStateSnapshot(
            appPID: runtimePID,
            isRunning: isRunning,
            isFollowingAgents: isFollowingAgents,
            followingAgents: followingAgents,
            mode: activeMode,
            closedLid: activeClosedLid,
            isIndefinite: isIndefinite,
            endDate: endDate,
            externalCLI: externalCLI,
            updatedAt: nowProvider()
        )
        RuntimeStateSnapshot.write(snapshot, to: runtimeStateURL)
    }
}
