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

/// The three scenes the popover can show. `isAuthorizing` and `externalCLI` render as banners on
/// top of any scene; `autoFollowSuppressed` is presentation inside the scene that owns the state.
public enum PopoverScene: Equatable, Sendable {
    case idle
    case manualRunning
    case following
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
    @Published public private(set) var autoFollowSuppressed: Bool = false
    /// Active source classes contributing to the current or paused auto-follow state.
    @Published public private(set) var activeAutoFollowSourceKind: AutoFollowSourceKind = .none
    /// Distinguishes an active hook lease that is holding wake protection from one that is paused or behind a manual timer.
    @Published public private(set) var hookProtectionStatus: HookProtectionStatus = .none
    /// True when the user asked to return from a manual closed-lid session to auto-follow and needs to confirm dropping lid protection.
    @Published public var pendingAutoFollowSwitchConfirmation: Bool = false
    /// Captures the exact parameters locked in for an in-flight admin authorization.
    @Published public private(set) var pendingAuthorizationLaunch: PendingAuthorizationLaunch? = nil
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

    /// Single source of truth for which scene the popover shows, derived only from
    /// `isRunning` / `isFollowingAgents`.
    public var popoverScene: PopoverScene {
        if isRunning && isFollowingAgents { return .following }
        if isRunning { return .manualRunning }
        return .idle
    }

    public var isAutoFollowEnabled: Bool {
        config.autoFollowAgents
    }

    public var currentAutoFollowSourceKind: AutoFollowSourceKind {
        let hasHook = hasActiveHookSessions
        let hasDir = config.autoFollowAgents && (directoryActivityStillHolding || agentTracker.evaluate().isHolding)
        switch (hasHook, hasDir) {
        case (true, true): return .both
        case (true, false): return .hookOnly
        case (false, true): return .directoryOnly
        case (false, false): return .none
        }
    }

    public var canSwitchToAutoFollow: Bool {
        isRunning && !isFollowingAgents && currentAutoFollowSourceKind != .none
    }

    private var canEngageUnprivilegedLidForAutoFollow: Bool {
        config.allowClosedLid && config.closedLidStrategy == .unprivileged && unprivilegedLidGuard != nil
    }

    public var dropsClosedLidOnAutoFollowSwitch: Bool {
        activeClosedLid && !(activeMode == .background && canEngageUnprivilegedLidForAutoFollow)
    }

    private func syncAutoFollowClosedLidGuard() {
        guard isRunning, isFollowingAgents else { return }
        if activeMode == .background, canEngageUnprivilegedLidForAutoFollow, let unprivilegedLidGuard {
            if !activeClosedLid {
                unprivilegedLidGuard.enable { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.activeClosedLid = true
                    case .failure(let error):
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        } else if activeClosedLid {
            backpackGuard.disable()
            unprivilegedLidGuard?.disable()
            activeClosedLid = false
        }
    }

    private func syncAutoFollowSourceKind() {
        let next = currentAutoFollowSourceKind
        if activeAutoFollowSourceKind != next {
            activeAutoFollowSourceKind = next
        }
        let nextHookStatus = computeHookProtectionStatus()
        if hookProtectionStatus != nextHookStatus {
            hookProtectionStatus = nextHookStatus
        }
        if !canSwitchToAutoFollow, pendingAutoFollowSwitchConfirmation {
            pendingAutoFollowSwitchConfirmation = false
        }
    }

    private func computeHookProtectionStatus() -> HookProtectionStatus {
        guard hasActiveHookSessions else { return .none }
        if isAuthorizing {
            if isRunning {
                return .waitingForAuthorization(existingProtection: isFollowingAgents ? .autoFollow : .manual)
            }
            return .waitingForAuthorization(existingProtection: nil)
        }
        if isRunning && isFollowingAgents {
            return .holding
        }
        if isRunning {
            return .standbyBehindManual
        }
        return .paused(limitReached: autoFollowLimitReached)
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
        if !hasActiveHookSessions {
            autoFollowLimitReached = false
        }
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
        syncAutoFollowSourceKind()
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
            guard !hasActiveHookSessions else {
                syncAutoFollowSourceKind()
                return
            }
            if state == .inactive {
                autoFollowSuppressed = false
                autoFollowLimitReached = false
                syncAutoFollowSourceKind()
                return
            }
            guard let previousActivity, let currentActivity = latestDirectoryActivity(in: state),
                  currentActivity.timeIntervalSince(previousActivity)
                    >= agentTracker.currentPolicy.activityWindow + agentTracker.currentPolicy.gracePeriod else {
                syncAutoFollowSourceKind()
                return
            }
            autoFollowSuppressed = false
            autoFollowLimitReached = false
        }

        // A manual session always wins; auto-follow never overrides it.
        //
        // The check must exclude sessions auto-follow started itself. `beginAutoFollow` sets
        // `isRunning`, so guarding on `isRunning` alone made the first `.active` block every
        // later transition — including `.inactive` — leaving `endAutoFollow` unreachable and the
        // assertion held for the full configured duration after the agents had gone quiet.
        guard !isRunning || isFollowingAgents else {
            syncAutoFollowSourceKind()
            return
        }

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
            syncAutoFollowSourceKind()
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
        } else {
            syncAutoFollowSourceKind()
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
        // Auto-follow runs in background mode, engages the standard no-auth closed-lid guard
        // when allowClosedLid is enabled, and is bounded by the agent policy's hard ceiling.
        let ceilingSeconds = max(1, Int(agentTracker.currentPolicy.maxAutoSessionDuration.rounded()))
        var lidEngaged = false
        if canEngageUnprivilegedLidForAutoFollow, let unprivilegedLidGuard {
            unprivilegedLidGuard.enable { [weak self] result in
                switch result {
                case .success:
                    lidEngaged = true
                case .failure:
                    guard let self else { return }
                    // The user asked for lid protection on this session: never swallow the
                    // guard failure, or closing the lid would silently sleep the Mac.
                    self.errorMessage = self.l10n.unprivilegedLidUnavailable
                }
            }
        }
        do {
            try caffeinateRunner.start(mode: .background, timeoutSeconds: ceilingSeconds + 30) { [weak self] in
                self?.handleCaffeinateExited()
            }
        } catch {
            if lidEngaged {
                unprivilegedLidGuard?.disable()
            }
            errorMessage = error.localizedDescription
            return
        }
        agentTracker.restartSessionWindow()
        activeMode = .background
        activeClosedLid = lidEngaged
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
        syncAutoFollowSourceKind()
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
            unprivilegedLidGuard?.disable()
            isRunning = false
            activeClosedLid = false
            activeSessionAgents = []
            endDate = nil
            remainingSeconds = 0
            syncAutoFollowSourceKind()
            notifyStateTransition()
        } else if wasRunning {
            stopSession(reason: .silent)
        } else {
            syncAutoFollowSourceKind()
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
        syncAutoFollowSourceKind()
        notifier.send(title: l10n.notifAutoFollowLimitTitle, body: l10n.notifAutoFollowLimitBody)
    }

    public func resetAutoFollowLimit() {
        autoFollowLimitReached = false
        if !hasActiveHookSessions, agentTracker.evaluate() == .inactive {
            autoFollowSuppressed = false
        }
        syncAutoFollowSourceKind()
    }

    /// Resumes automatic following after a manual pause or 2-hour ceiling stop.
    public func resumeAutoFollow() {
        errorMessage = nil
        autoFollowSuppressed = false
        autoFollowLimitReached = false
        if config.autoFollowAgents {
            agentTracker.restartSessionWindow()
        }
        let trackerState = config.autoFollowAgents ? agentTracker.evaluate() : .inactive
        lastAgentActivityState = trackerState
        syncAutoFollowSourceKind()

        guard !isRunning, !isAuthorizing else { return }
        if hasActiveHookSessions || (config.autoFollowAgents && trackerState.isHolding) {
            let merged = mergedFollowingAgents()
            followingAgents = merged
            activeSessionAgents = merged
            if !hasActiveHookSessions, case .grace(let since) = trackerState {
                autoFollowGraceEndDate = since.addingTimeInterval(agentTracker.currentPolicy.gracePeriod)
            } else {
                autoFollowGraceEndDate = nil
            }
            beginAutoFollow()
        } else {
            notifyStateTransition()
        }
    }

    /// Starts or refreshes an explicit hook lease (e.g., from Claude Code `UserPromptSubmit`).
    public func handleHookStart(sessionID: String, agent: String) {
        let key = normalizedHookSessionID(sessionID, agent: agent)
        let displayAgent = AgentSource.displayName(forIdentifier: agent)
        activeHookSessions[key] = HookLease(sessionID: sessionID, agent: displayAgent, startedAt: nowProvider())

        // Manual sessions always win; track the lease silently until manual ends.
        guard !isRunning || isFollowingAgents else {
            syncAutoFollowSourceKind()
            return
        }

        guard !autoFollowSuppressed else {
            syncAutoFollowSourceKind()
            return
        }
        let hookAgents = mergedFollowingAgents()
        followingAgents = hookAgents
        if !hookAgents.isEmpty {
            activeSessionAgents = hookAgents
        }
        autoFollowGraceEndDate = nil
        autoFollowGraceRemainingSeconds = 0
        syncAutoFollowSourceKind()

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
            autoFollowLimitReached = false
            syncAutoFollowSourceKind()
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
            syncAutoFollowSourceKind()
            writeRuntimeStateSnapshot()
            refreshDisplayTick()
        } else {
            syncAutoFollowSourceKind()
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
        if isRunning && isFollowingAgents && activeMode != mode {
            switchRunningMode(to: mode)
        }
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
        if isRunning && isFollowingAgents {
            syncAutoFollowClosedLidGuard()
            notifyStateTransition()
        }
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
        if !isRunning {
            unprivilegedLidGuard?.disable()
        }
        isAuthorizing = true
        pendingAuthorizationLaunch = PendingAuthorizationLaunch(
            mode: mode,
            durationMinutes: minutes,
            lockOnStart: lockImmediately,
            closedLidStrategy: .privileged
        )
        // An authorization dialog that is dismissed without a result, or an AppleScript call
        // that never returns, used to leave the button spinning forever with no way out.
        let authorizationToken = UUID()
        activeAuthorizationToken = authorizationToken
        syncAutoFollowSourceKind()
        notifyStateTransition()
        authorizationScheduler(120) { [weak self] in
            guard let self, self.isAuthorizing, self.activeAuthorizationToken == authorizationToken else { return }
            self.isAuthorizing = false
            self.activeAuthorizationToken = nil
            self.pendingAuthorizationLaunch = nil
            self.backpackGuard.disable()
            self.stopIdleSafetyWatches()
            self.errorMessage = self.l10n.authorizationTimedOut
            self.syncAutoFollowSourceKind()
            self.notifyStateTransition()
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
            self.pendingAuthorizationLaunch = nil
            switch result {
            case .success:
                self.staleSleepDisabled = false
                self.launchCaffeinate(mode: mode, minutes: minutes, closedLid: true, lockImmediately: lockImmediately)
            case .failure(let error):
                self.stopIdleSafetyWatches()
                self.errorMessage = error.localizedDescription
                self.syncAutoFollowSourceKind()
                self.notifyStateTransition()
            }
        }
    }

    public func cancelAuthorization() {
        guard isAuthorizing else { return }
        activeAuthorizationToken = nil
        isAuthorizing = false
        pendingAuthorizationLaunch = nil
        pendingAutoFollowSwitchConfirmation = false
        if !activeClosedLid {
            backpackGuard.disable()
        }
        stopIdleSafetyWatches()
        syncAutoFollowSourceKind()
        notifyStateTransition()
    }

    private func launchCaffeinate(mode: GuardMode, minutes: Double, closedLid: Bool, lockImmediately: Bool) {
        // Authorization can take up to two minutes; power and thermal conditions may have
        // changed since the request. Reject before replacing an assertion or locking the screen.
        guard passesPowerAndThermalPreflight() else {
            if closedLid {
                backpackGuard.disable()
                if !isRunning || !activeClosedLid {
                    unprivilegedLidGuard?.disable()
                }
            }
            stopIdleSafetyWatches()
            // Authorization may already have completed. Publish the protection that actually
            // remains, including an older session retained when this replacement is rejected.
            syncAutoFollowSourceKind()
            notifyStateTransition()
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
                if !isRunning || !activeClosedLid {
                    unprivilegedLidGuard?.disable()
                }
            }
            stopIdleSafetyWatches()
            errorMessage = error.localizedDescription
            syncAutoFollowSourceKind()
            notifyStateTransition()
            return
        }

        if closedLid, config.closedLidStrategy == .privileged {
            unprivilegedLidGuard?.disable()
        }
        if isFollowingAgents {
            recordCompletedSession(stopReasonCode: "manualPromotion")
            isFollowingAgents = false
            followingAgents = []
            activeAutoFollowSourceKind = .none
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
        pendingAutoFollowSwitchConfirmation = false
        showCustomInput = false
        showSettings = false
        syncAutoFollowSourceKind()
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
        guard isRunning, !isAuthorizing, newMode != activeMode else { return }
        errorMessage = nil

        if isFollowingAgents {
            let remainingUntilCap = max(
                1,
                Int((endDate?.timeIntervalSince(nowProvider()) ?? agentTracker.currentPolicy.maxAutoSessionDuration).rounded(.up))
            )
            do {
                try caffeinateRunner.start(mode: newMode, timeoutSeconds: remainingUntilCap + 30) { [weak self] in
                    self?.handleCaffeinateExited()
                }
                activeMode = newMode
                syncAutoFollowClosedLidGuard()
                notifyStateTransition()
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }

        let remainingTimeout: Int?
        if isIndefinite {
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
                pendingAutoFollowSwitchConfirmation = false
            }
            config.mode = newMode
            persistConfig()
            syncAutoFollowSourceKind()
            notifyStateTransition()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Explicitly hands off an active auto-follow session to the user's configured manual timer.
    public func promoteAutoFollowToManual() {
        guard isRunning, isFollowingAgents, !isAuthorizing else { return }
        errorMessage = nil
        let targetMinutes = config.durationMinutes
        if activeMode == .background, config.allowClosedLid, config.closedLidStrategy == .privileged {
            startPrivilegedLidGuard(
                mode: activeMode,
                minutes: targetMinutes,
                lockImmediately: config.effectiveLockOnStart
            )
            return
        }
        let timeoutSec = CommandBuilder.timeoutSeconds(forMinutes: targetMinutes)

        do {
            try caffeinateRunner.start(mode: activeMode, timeoutSeconds: timeoutSec) { [weak self] in
                self?.handleCaffeinateExited()
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        if activeMode == .background, canEngageUnprivilegedLidForAutoFollow, let unprivilegedLidGuard {
            if !activeClosedLid {
                unprivilegedLidGuard.enable { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.activeClosedLid = true
                    case .failure(let error):
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        } else if !config.allowClosedLid, activeClosedLid {
            backpackGuard.disable()
            unprivilegedLidGuard?.disable()
            activeClosedLid = false
        }

        recordCompletedSession(stopReasonCode: "manualPromotion")
        isFollowingAgents = false
        followingAgents = []
        activeAutoFollowSourceKind = .none
        pendingAutoFollowSwitchConfirmation = false
        autoFollowGraceEndDate = nil
        autoFollowGraceRemainingSeconds = 0
        isIndefinite = (timeoutSec == nil)
        initialMinutes = targetMinutes
        let now = nowProvider()
        activeSessionStartDate = now
        activeSessionTrigger = .manual
        activeSessionAgents = []
        endDate = timeoutSec.map { now.addingTimeInterval(TimeInterval($0)) }
        syncAutoFollowSourceKind()
        refreshDisplayTick()
        notifyStateTransition()

        // launchCaffeinate locks the screen after a lockOnStart manual start. Promotion produces
        // the same manual session, so the non-privileged path must honor the same promise — the
        // privileged branch already does via startPrivilegedLidGuard.
        if config.effectiveLockOnStart {
            onRequestClosePopover?()
            screenLocker.lockScreen()
        }
    }

    /// Requests switching a running manual session back to auto-follow. When closed-lid protection
    /// would be dropped, stages an explicit confirmation rather than silently dropping lid protection.
    public func requestSwitchManualToAutoFollow() {
        guard isRunning, !isFollowingAgents, !isAuthorizing, canSwitchToAutoFollow else { return }
        if dropsClosedLidOnAutoFollowSwitch {
            pendingAutoFollowSwitchConfirmation = true
        } else {
            pendingAutoFollowSwitchConfirmation = false
            switchManualToAutoFollow()
        }
    }

    public func cancelSwitchToAutoFollow() {
        pendingAutoFollowSwitchConfirmation = false
    }

    /// Returns a running manual session back to auto-follow when at least one automatic source is active.
    public func switchManualToAutoFollow() {
        guard isRunning, !isFollowingAgents, !isAuthorizing, canSwitchToAutoFollow else { return }
        errorMessage = nil
        pendingAutoFollowSwitchConfirmation = false
        let ceilingSeconds = max(1, Int(agentTracker.currentPolicy.maxAutoSessionDuration.rounded()))
        let completedManualClosedLid = activeClosedLid
        // The standard no-auth guard takes over lid protection; when it is not available the
        // guard is dropped together with the manual session.
        let lidHandoffGuard = (activeMode == .background && canEngageUnprivilegedLidForAutoFollow)
            ? unprivilegedLidGuard : nil

        // Engage the standard guard before anything else is torn down: if it cannot take over,
        // abort the switch so the manual session keeps its own protection instead of continuing
        // into an unprotected auto-follow.
        if let lidHandoffGuard, !lidHandoffGuard.isEngaged {
            var engaged = false
            lidHandoffGuard.enable { result in
                if case .success = result { engaged = true }
            }
            guard engaged else {
                errorMessage = l10n.unprivilegedLidUnavailable
                return
            }
        }

        do {
            try caffeinateRunner.start(mode: activeMode, timeoutSeconds: ceilingSeconds + 30) { [weak self] in
                self?.handleCaffeinateExited()
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        if lidHandoffGuard != nil {
            backpackGuard.disable()
        } else if completedManualClosedLid {
            backpackGuard.disable()
            unprivilegedLidGuard?.disable()
        }

        // Record while activeClosedLid still reflects the manual session, then publish the
        // auto-follow value.
        recordCompletedSession(stopReasonCode: "manual")
        activeClosedLid = lidHandoffGuard?.isEngaged ?? false
        autoFollowSuppressed = false
        autoFollowLimitReached = false
        if config.autoFollowAgents {
            agentTracker.restartSessionWindow()
        }
        let trackerState = config.autoFollowAgents ? agentTracker.evaluate() : .inactive
        lastAgentActivityState = trackerState
        let merged = mergedFollowingAgents()
        followingAgents = merged
        activeSessionAgents = merged
        if !hasActiveHookSessions, case .grace(let since) = trackerState {
            autoFollowGraceEndDate = since.addingTimeInterval(agentTracker.currentPolicy.gracePeriod)
        } else {
            autoFollowGraceEndDate = nil
        }
        let now = nowProvider()
        activeSessionStartDate = now
        activeSessionTrigger = .autoFollow
        isIndefinite = false
        initialMinutes = Double(ceilingSeconds) / 60.0
        endDate = now.addingTimeInterval(TimeInterval(ceilingSeconds))
        isFollowingAgents = true
        syncAutoFollowSourceKind()
        refreshDisplayTick()
        notifyStateTransition()
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
        pendingAuthorizationLaunch = nil
        pendingAutoFollowSwitchConfirmation = false

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
        syncAutoFollowSourceKind()
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
