import Combine
import Foundation
import Testing
@testable import SleepSkipCore

private final class MockCaffeinateRunner: CaffeinateRunning {
    var isActive: Bool = false
    var shouldThrowOnStart = false
    var startCount = 0
    var stopCount = 0
    var lastMode: GuardMode?
    var lastTimeout: Int?
    var exitCallback: (() -> Void)?

    func start(mode: GuardMode, timeoutSeconds: Int?, onUnexpectedExit: @escaping () -> Void) throws {
        if shouldThrowOnStart {
            throw NSError(domain: "MockCaffeinate", code: 1, userInfo: [NSLocalizedDescriptionKey: "spawn failed"])
        }
        startCount += 1
        isActive = true
        lastMode = mode
        lastTimeout = timeoutSeconds
        exitCallback = onUnexpectedExit
    }

    func stop() {
        stopCount += 1
        isActive = false
    }
}

private final class MockBackpackGuard: BackpackGuarding {
    var enableCalls = 0
    var enabled = false
    var disableCalls = 0
    var shouldFailEnable = false
    var deferEnableCompletion = false
    private var pendingEnableCompletions: [(Result<Void, Error>) -> Void] = []

    func enable(completion: @escaping (Result<Void, Error>) -> Void) {
        enableCalls += 1
        if deferEnableCompletion {
            pendingEnableCompletions.append(completion)
            return
        }
        completeEnable(completion)
    }

    func finishPendingEnable() {
        guard !pendingEnableCompletions.isEmpty else { return }
        completeEnable(pendingEnableCompletions.removeFirst())
    }

    private func completeEnable(_ completion: (Result<Void, Error>) -> Void) {
        if shouldFailEnable {
            completion(.failure(NSError(domain: "MockBackpack", code: -1, userInfo: [NSLocalizedDescriptionKey: "auth cancelled"])))
        } else {
            enabled = true
            completion(.success(()))
        }
    }

    func disable() {
        disableCalls += 1
        enabled = false
    }

    func checkSleepDisabledAsync(completion: @escaping (Bool) -> Void) {
        completion(false)
    }

    func restoreNormalSleepAsync(completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }
}

private final class MockPowerMonitor: PowerMonitoring {
    var snapshot: PowerSnapshot? = PowerSnapshot(onBattery: false, percentage: 100)
    var startedThreshold: Int = 0
    var startedStopOnUnplug: Bool = false
    var eventHandler: ((PowerEvent) -> Void)?

    func currentPowerSnapshot() -> PowerSnapshot? {
        snapshot
    }

    func start(thresholdPercent: Int, stopOnUnplug: Bool, onEvent: @escaping (PowerEvent) -> Void) {
        startedThreshold = thresholdPercent
        startedStopOnUnplug = stopOnUnplug
        eventHandler = onEvent
    }

    func stop() {
        eventHandler = nil
    }
}

private final class MockScreenLocker: ScreenLocking {
    var lockCount = 0
    func lockScreen() { lockCount += 1 }
}

private final class MockNotifier: UserNotifying {
    var prepareCount = 0
    var sent: [(String, String)] = []
    func preparePermissionIfNeeded() { prepareCount += 1 }
    func send(title: String, body: String) { sent.append((title, body)) }
}

private final class MockLoginItem: LoginItemControlling {
    var isEnabled: Bool = false
    func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}

private final class MockThermalMonitor: ThermalMonitoring {
    var overheated = false
    var triggerHandler: (() -> Void)?
    func isOverheated(cutoff: ThermalCutoff) -> Bool {
        cutoff != .off && overheated
    }
    func start(cutoff: ThermalCutoff, onOverheated: @escaping () -> Void) {
        triggerHandler = onOverheated
    }
    func stop() {
        triggerHandler = nil
    }
}

private final class MockCLIInstaller: CLIInstalling {
    var status: CLIInstallStatus = .notInstalled
    var nextResult: Result<String, Error> = .success("/usr/local/bin/sleepskip")
    func currentStatus() -> CLIInstallStatus { status }
    func install(completion: @escaping (Result<String, Error>) -> Void) {
        if case let .success(path) = nextResult {
            status = .installed(path: path)
        }
        completion(nextResult)
    }
}

@Suite("SleepSkip Core")
struct SleepSkipCoreTests {
    @Test func commandBuilderBuildsBackgroundAndKeepDisplayArguments() {
        let bg = CommandBuilder.caffeinateArguments(mode: .background, parentPID: 1234, timeoutSeconds: 14400)
        #expect(bg == ["-i", "-w", "1234", "-t", "14400"])

        let disp = CommandBuilder.caffeinateArguments(mode: .keepDisplay, parentPID: 5678, timeoutSeconds: nil)
        #expect(disp == ["-di", "-w", "5678"])

        #expect(CommandBuilder.timeoutSeconds(forMinutes: 0) == nil)
        #expect(CommandBuilder.timeoutSeconds(forMinutes: 240) == 14400)
    }

    @Test func urlCommandAndCLIParser() {
        let startURL = URL(string: "sleepskip://start?mode=display&minutes=90&lock=0&lid=0")!
        #expect(
            URLCommandParser.parse(startURL) ==
            .start(mode: .keepDisplay, minutes: 90, lockOnStart: false, allowClosedLid: false)
        )
        #expect(URLCommandParser.parse(URL(string: "sleepskip://stop")!) == .stop)
        #expect(URLCommandParser.parse(URL(string: "sleepskip://lock")!) == .lock)
        #expect(URLCommandParser.parse(URL(string: "https://example.com")!) == nil)

        #expect(
            CLIParser.parse(arguments: ["SleepSkip", "--display", "--lock", "--", "codex", "run"]) ==
            .runCommand(arguments: ["codex", "run"], mode: .keepDisplay, lockOnFinish: true)
        )
        #expect(
            CLIParser.parse(arguments: ["SleepSkip", "watch", "4321", "--lock"]) ==
            .watchPID(pid: 4321, mode: .background, lockOnFinish: true)
        )
        #expect(CLIParser.parse(arguments: ["SleepSkip", "--open"]) == .gui(openPopover: true))
    }

    @Test func cliParserDoesNotHijackPassthroughArguments() {
        #expect(
            CLIParser.parse(arguments: ["SleepSkip", "--", "codex", "--version"]) ==
            .runCommand(arguments: ["codex", "--version"], mode: .background, lockOnFinish: false)
        )
        #expect(
            CLIParser.parse(arguments: ["SleepSkip", "--", "npm", "-v"]) ==
            .runCommand(arguments: ["npm", "-v"], mode: .background, lockOnFinish: false)
        )
        #expect(
            CLIParser.parse(arguments: ["SleepSkip", "--", "claude", "--help"]) ==
            .runCommand(arguments: ["claude", "--help"], mode: .background, lockOnFinish: false)
        )
        #expect(CLIParser.parse(arguments: ["SleepSkip", "--version"]) == .version)
        #expect(CLIParser.parse(arguments: ["SleepSkip", "--help"]) == .help)
        #expect(CLIParser.parse(arguments: ["SleepSkip", "--"]) == .help)
    }

    @Test func nonFiniteDurationsAreRejected() {
        for raw in ["inf", "Infinity", "-inf", "1e999", "nan"] {
            guard let value = Double(raw) else { continue }
            #expect(CommandBuilder.timeoutSeconds(forMinutes: value) == nil, "\(raw) must not produce a timeout")
        }
        #expect(
            CommandBuilder.timeoutSeconds(forMinutes: 1e300) ==
            CommandBuilder.timeoutSeconds(forMinutes: CommandBuilder.maxDurationMinutes)
        )
        #expect(CommandBuilder.sanitizeMinutes(.infinity) == nil)
        #expect(CommandBuilder.sanitizeMinutes(.nan) == nil)
        #expect(CommandBuilder.sanitizeMinutes(-5) == nil)
        #expect(
            CommandBuilder.sanitizeMinutes(CommandBuilder.maxDurationMinutes * 10) ==
            CommandBuilder.maxDurationMinutes
        )
        #expect(DurationFormatter.formatDuration(.infinity, isChinese: false) == "Indefinite")
        #expect(DurationFormatter.formatDuration(.nan, isChinese: true) == "永久")
        #expect(DurationFormatter.formatShortPreset(.infinity, isChinese: false) == "∞")

        let suiteName = "io.github.laiyongqiang.SleepSkip.poison.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Double.infinity, forKey: "sleepskip.durationMinutes")
        defaults.set(Double.nan, forKey: "sleepskip.customMinutes")
        let loaded = PreferencesStore(defaults: defaults).load()
        #expect(loaded.durationMinutes == 240)
        #expect(loaded.customMinutes == 90)
    }

    @Test func urlMinutesSanitized() {
        let inf = URLCommandParser.parse(URL(string: "sleepskip://start?minutes=inf")!)
        #expect(inf == .start(mode: nil, minutes: nil, lockOnStart: nil, allowClosedLid: nil))
        let huge = URLCommandParser.parse(URL(string: "sleepskip://start?minutes=1e300")!)
        #expect(
            huge ==
            .start(mode: nil, minutes: CommandBuilder.maxDurationMinutes, lockOnStart: nil, allowClosedLid: nil)
        )
    }

    @Test func migratesSettingsFromPreRenameDomain() throws {
        let newSuite = "io.github.laiyongqiang.SleepSkip.migrate.\(UUID().uuidString)"
        let oldSuite = "io.github.laiyongqiang.SleepGuard.migrate.\(UUID().uuidString)"
        let newDefaults = try #require(UserDefaults(suiteName: newSuite))
        let oldDefaults = try #require(UserDefaults(suiteName: oldSuite))
        defer {
            newDefaults.removePersistentDomain(forName: newSuite)
            oldDefaults.removePersistentDomain(forName: oldSuite)
        }

        oldDefaults.set("keepDisplay", forKey: "sleepguard.mode")
        oldDefaults.set(90.0, forKey: "sleepguard.durationMinutes")
        oldDefaults.set("en", forKey: "sleepguard.language")

        PreferencesStore.migrateFromLegacyDomainIfNeeded(defaults: newDefaults, legacyDefaults: oldDefaults)
        let migrated = PreferencesStore(defaults: newDefaults).load()
        #expect(migrated.mode == .keepDisplay)
        #expect(migrated.durationMinutes == 90)
        #expect(migrated.language == .en)

        oldDefaults.set("background", forKey: "sleepguard.mode")
        PreferencesStore.migrateFromLegacyDomainIfNeeded(defaults: newDefaults, legacyDefaults: oldDefaults)
        #expect(PreferencesStore(defaults: newDefaults).load().mode == .keepDisplay)
    }

    @Test func migrationDoesNotOverwriteExistingSettings() throws {
        let newSuite = "io.github.laiyongqiang.SleepSkip.existing.\(UUID().uuidString)"
        let oldSuite = "io.github.laiyongqiang.SleepGuard.existing.\(UUID().uuidString)"
        let newDefaults = try #require(UserDefaults(suiteName: newSuite))
        let oldDefaults = try #require(UserDefaults(suiteName: oldSuite))
        defer {
            newDefaults.removePersistentDomain(forName: newSuite)
            oldDefaults.removePersistentDomain(forName: oldSuite)
        }

        newDefaults.set("background", forKey: "sleepskip.mode")
        oldDefaults.set("keepDisplay", forKey: "sleepguard.mode")

        PreferencesStore.migrateFromLegacyDomainIfNeeded(defaults: newDefaults, legacyDefaults: oldDefaults)
        #expect(PreferencesStore(defaults: newDefaults).load().mode == .background)
    }

    @Test func preferencesPersistenceRoundTrip() throws {
        let suiteName = "io.github.laiyongqiang.SleepSkip.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PreferencesStore(defaults: defaults)
        let initial = store.load()
        #expect(initial.mode == .background)
        #expect(initial.durationMinutes == 240)
        #expect(initial.lockOnStart == false)
        #expect(initial.allowClosedLid == false)
        #expect(initial.stopOnUnplug == false)
        #expect(initial.autoFollowAgents == true)
        #expect(initial.batteryThresholdPercent == 10)

        var updated = initial
        updated.mode = .keepDisplay
        updated.durationMinutes = 90
        updated.customMinutes = 90
        updated.lockOnStart = true
        updated.allowClosedLid = true
        updated.stopOnUnplug = true
        updated.autoFollowAgents = false
        updated.language = .en
        store.save(updated)

        #expect(store.load() == updated)

        // Existing installs without an explicit lockOnStart key preserve legacy true behavior.
        let legacySuite = "io.github.laiyongqiang.SleepSkip.legacyLock.\(UUID().uuidString)"
        let legacyDefaults = try #require(UserDefaults(suiteName: legacySuite))
        defer { legacyDefaults.removePersistentDomain(forName: legacySuite) }
        legacyDefaults.set("background", forKey: "sleepskip.mode")
        #expect(PreferencesStore(defaults: legacyDefaults).load().lockOnStart == true)
    }

    @Test func sessionManagerLifecycleAndPreFlightGuards() throws {
        let suiteName = "io.github.laiyongqiang.SleepSkip.sm.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferencesStore(defaults: defaults)

        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let caf = MockCaffeinateRunner()
        let bag = MockBackpackGuard()
        let pwr = MockPowerMonitor()
        let lock = MockScreenLocker()
        let notif = MockNotifier()
        let login = MockLoginItem()

        let manager = SessionManager(
            store: store,
            caffeinateRunner: caf,
            backpackGuard: bag,
            powerMonitor: pwr,
            screenLocker: lock,
            notifier: notif,
            loginItem: login,
            nowProvider: { currentTime },
            checkStaleSleepOnInit: false
        )

        var closeCount = 0
        manager.onRequestClosePopover = { closeCount += 1 }

        manager.setClosedLidStrategy(.privileged)
        manager.setAllowClosedLid(true)
        pwr.snapshot = PowerSnapshot(onBattery: true, percentage: 8)
        manager.startConfiguredSession()
        #expect(!manager.isRunning)
        #expect(bag.enableCalls == 0)
        #expect(manager.errorMessage != nil)

        pwr.snapshot = PowerSnapshot(onBattery: false, percentage: 90)
        manager.selectMode(.keepDisplay)
        manager.startConfiguredSession()
        #expect(manager.isRunning)
        #expect(closeCount == 0)
        #expect(lock.lockCount == 0)
        #expect(notif.sent.isEmpty)

        currentTime = currentTime.addingTimeInterval(100)
        manager.refreshDisplayTick()
        #expect(manager.remainingSeconds == 14300)

        manager.extendSession(byMinutes: 30)
        #expect(manager.remainingSeconds == 16100)

        caf.shouldThrowOnStart = true
        manager.switchRunningMode(to: .background)
        #expect(manager.activeMode == .keepDisplay)
        #expect(manager.errorMessage != nil)

        caf.shouldThrowOnStart = false
        manager.switchRunningMode(to: .background)
        #expect(manager.activeMode == .background)

        caf.isActive = false
        manager.reconcileOnWakeOrShow()
        #expect(!manager.isRunning)
        #expect(notif.sent.count == 1)

        currentTime = currentTime.addingTimeInterval(100)
        manager.startConfiguredSession()
        #expect(manager.isRunning)
        #expect(caf.isActive)
        currentTime = currentTime.addingTimeInterval(14_405)
        manager.reconcileOnWakeOrShow()
        #expect(!manager.isRunning)
        #expect(!caf.isActive)
        #expect(notif.sent.count == 2)
    }

    @Test func liveCaffeinateProcessExitsWhenSentinelExits() throws {
        let sentinel = Process()
        sentinel.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sentinel.arguments = ["10"]
        try sentinel.run()

        let caffeinate = Process()
        caffeinate.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        caffeinate.arguments = CommandBuilder.caffeinateArguments(
            mode: .background,
            parentPID: sentinel.processIdentifier,
            timeoutSeconds: 30
        )
        try caffeinate.run()

        usleep(150_000)
        #expect(caffeinate.isRunning)

        sentinel.terminate()
        sentinel.waitUntilExit()
        caffeinate.waitUntilExit()

        #expect(!caffeinate.isRunning)
        #expect(caffeinate.terminationStatus == 0)
    }

    @Test func closedLidLaunchScriptQuotesPathsWithSpaces() {
        let script = "/Users/me/Library/Application Support/SleepSkip/lid-guard.sh"
        let pid = script + ".pid"
        let command = CommandBuilder.closedLidLaunchScript(scriptPath: script, pidPath: pid)

        #expect(command.contains("'/Users/me/Library/Application Support/SleepSkip/lid-guard.sh'"))
        #expect(command.contains("'/Users/me/Library/Application Support/SleepSkip/lid-guard.sh.pid'"))
        #expect(!command.contains("/bin/sh /Users/me/Library/Application "))
    }

    @Test func shellSingleQuotingEscapesEmbeddedApostrophes() {
        #expect(CommandBuilder.shellSingleQuoted("/tmp/plain") == "'/tmp/plain'")
        #expect(CommandBuilder.shellSingleQuoted("/tmp/it's") == "'/tmp/it'\\''s'")
        #expect(CommandBuilder.shellSingleQuoted("") == "''")
    }

    @Test func closedLidLaunchScriptActuallyRunsTheGuard() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SleepSkip Test \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let marker = dir.appendingPathComponent("ran.txt")
        let scriptURL = dir.appendingPathComponent("lid-guard.sh")
        try "#!/bin/sh\necho ok > \(CommandBuilder.shellSingleQuoted(marker.path))\n"
            .write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let command = CommandBuilder.closedLidLaunchScript(
            scriptPath: scriptURL.path,
            pidPath: scriptURL.path + ".pid"
        )
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", command]
        try shell.run()
        shell.waitUntilExit()

        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            usleep(50_000)
        }
        #expect(
            FileManager.default.fileExists(atPath: marker.path),
            "quoted launch command did not execute the guard script"
        )
    }

    private func makeManager(
        caf: MockCaffeinateRunner,
        bag: MockBackpackGuard = MockBackpackGuard(),
        notif: MockNotifier = MockNotifier(),
        power: MockPowerMonitor = MockPowerMonitor(),
        thermal: MockThermalMonitor? = nil,
        locker: MockScreenLocker = MockScreenLocker(),
        now: @escaping () -> Date = { Date() }
    ) throws -> (SessionManager, UserDefaults, String) {
        let suiteName = "io.github.laiyongqiang.SleepSkip.af.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let manager = SessionManager(
            store: PreferencesStore(defaults: defaults),
            caffeinateRunner: caf,
            backpackGuard: bag,
            powerMonitor: power,
            thermalMonitor: thermal,
            screenLocker: locker,
            notifier: notif,
            loginItem: MockLoginItem(),
            nowProvider: now,
            checkStaleSleepOnInit: false
        )
        return (manager, defaults, suiteName)
    }

    @Test func autoFollowReleasesWhenAgentsGoQuiet() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let caf = MockCaffeinateRunner()
        let (manager, defaults, suite) = try makeManager(caf: caf, now: { now })
        defer { defaults.removePersistentDomain(forName: suite) }

        manager.setAutoFollowEnabled(true)
        manager.selectDuration(30)
        manager.handleAgentActivity(.active(agents: ["claude-code"], lastActivity: now))
        #expect(manager.isRunning, "auto-follow should start a session")
        #expect(manager.isFollowingAgents)
        #expect(manager.remainingSeconds == 7200)

        manager.handleAgentActivity(.grace(since: now))
        #expect(manager.autoFollowGraceEndDate != nil)
        #expect(manager.autoFollowGraceRemainingSeconds == 300)

        manager.handleAgentActivity(.inactive)
        #expect(!manager.isRunning, "auto-follow must release once the agents go quiet")
        #expect(!manager.isFollowingAgents)
        #expect(manager.autoFollowGraceEndDate == nil)
        #expect(caf.stopCount == 1)
    }

    @Test func modeSwitchDuringAutoFollowPreservesLifecycleAcrossSavedPresets() throws {
        for savedDuration in [1.0, 240.0, 0.0] {
            var now = Date(timeIntervalSince1970: 1_700_000_000)
            let caf = MockCaffeinateRunner()
            let (manager, defaults, suite) = try makeManager(caf: caf, now: { now })
            defer { defaults.removePersistentDomain(forName: suite) }

            manager.selectMode(.background)
            manager.selectDuration(savedDuration)
            manager.setAutoFollowEnabled(true)
            manager.handleAgentActivity(.active(agents: ["claude-code"], lastActivity: now))
            #expect(manager.isFollowingAgents)
            let autoEnd = manager.endDate

            now = now.addingTimeInterval(20)
            manager.switchRunningMode(to: .keepDisplay)
            #expect(manager.isRunning)
            #expect(manager.isFollowingAgents, "display mode switch must keep auto-follow lifecycle")
            #expect(manager.activeMode == .keepDisplay)
            #expect(!manager.isIndefinite, "indefinite manual preset must not leak into auto-follow")
            #expect(manager.endDate == autoEnd, "2h ceiling must be preserved")
            #expect(manager.config.mode == .background, "saved manual mode must stay unchanged")
            #expect(caf.lastTimeout == 7210)

            manager.switchRunningMode(to: .background)
            #expect(manager.isFollowingAgents)
            #expect(manager.activeMode == .background)
            #expect(manager.endDate == autoEnd)

            manager.handleAgentActivity(.inactive)
            #expect(!manager.isRunning, "auto-follow session must still release on quiet after mode toggle")
            #expect(!manager.isFollowingAgents)
        }
    }

    @Test func explicitManualPromotionAndReturnToAutoFollow() throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let caf = MockCaffeinateRunner()
        let (manager, defaults, suite) = try makeManager(caf: caf, now: { now })
        defer { defaults.removePersistentDomain(forName: suite) }

        manager.setAutoFollowEnabled(true)
        manager.selectDuration(1)
        manager.agentTracker.recordActivity(sourceID: "claude-code")
        manager.handleAgentActivity(manager.agentTracker.evaluate())
        #expect(manager.isFollowingAgents)
        #expect(manager.remainingSeconds == 7200)

        manager.promoteAutoFollowToManual()
        #expect(manager.isRunning)
        #expect(!manager.isFollowingAgents)
        #expect(manager.remainingSeconds == 60)
        #expect(manager.canSwitchToAutoFollow)

        manager.switchManualToAutoFollow()
        #expect(manager.isFollowingAgents)
        #expect(manager.remainingSeconds == 7200)

        manager.promoteAutoFollowToManual()
        now = now.addingTimeInterval(400)
        manager.handleAgentActivity(.inactive)
        #expect(manager.isRunning, "explicit manual session must survive agents going quiet")
        #expect(!manager.canSwitchToAutoFollow)
    }

    @Test func pauseResumeAndCancelAuthorizationStates() throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let caf = MockCaffeinateRunner()
        let bag = MockBackpackGuard()
        let (manager, defaults, suite) = try makeManager(caf: caf, bag: bag, now: { now })
        defer { defaults.removePersistentDomain(forName: suite) }

        // Manual stop while active surfaces paused state and resumeAutoFollow restores immediately.
        manager.setAutoFollowEnabled(true)
        manager.agentTracker.recordActivity(sourceID: "codex")
        manager.handleAgentActivity(manager.agentTracker.evaluate())
        #expect(manager.isFollowingAgents)
        #expect(manager.activeAutoFollowSourceKind == .directoryOnly)

        manager.stopSession(reason: .manual)
        #expect(!manager.isRunning)
        #expect(manager.autoFollowSuppressed)
        #expect(!manager.autoFollowLimitReached)

        manager.resumeAutoFollow()
        #expect(manager.isFollowingAgents)
        #expect(!manager.autoFollowSuppressed)

        // 2h limit sets paused+limit state, and resumeAutoFollow restarts with a fresh 2h cap.
        manager.handleAutoFollowLimitReached()
        #expect(!manager.isRunning)
        #expect(manager.autoFollowSuppressed)
        #expect(manager.autoFollowLimitReached)

        now = now.addingTimeInterval(10)
        manager.resumeAutoFollow()
        #expect(manager.isFollowingAgents)
        #expect(!manager.autoFollowSuppressed)
        #expect(!manager.autoFollowLimitReached)
        #expect(manager.remainingSeconds == 7200)

        // Cancelling pending admin authorization via cancelAuthorization drops pending state and ignores late success.
        manager.stopSession(reason: .manual)
        manager.handleAgentActivity(.inactive)
        bag.deferEnableCompletion = true
        manager.setClosedLidStrategy(.privileged)
        manager.setAllowClosedLid(true)
        manager.startConfiguredSession()
        #expect(manager.isAuthorizing)
        #expect(manager.pendingAuthorizationLaunch != nil)

        manager.cancelAuthorization()
        #expect(!manager.isAuthorizing)
        #expect(manager.pendingAuthorizationLaunch == nil)
        #expect(!manager.autoFollowSuppressed)
        let startsBeforeLateAuth = caf.startCount
        bag.finishPendingEnable()
        #expect(!manager.isRunning)
        #expect(caf.startCount == startsBeforeLateAuth)
        #expect(!bag.enabled)
    }

    @Test func l10nHonestBoundaryCopyAndSourceDistinction() {
        let zh = L10n(language: .zhHans)
        let en = L10n(language: .en)

        var cfg = SessionConfig(mode: .background, durationMinutes: 60, lockOnStart: false, allowClosedLid: false)
        #expect(!zh.launchConfigSummary(cfg).contains("上次配置"))
        #expect(!en.launchConfigSummary(cfg).contains("Last:"))
        #expect(zh.startButtonTitle(for: cfg) == "开始保持唤醒 (⏎)")
        cfg.lockOnStart = true
        #expect(zh.startButtonTitle(for: cfg) == "开始并锁屏 (⏎)")
        #expect(en.startButtonTitle(for: cfg) == "Start & Lock Screen (⏎)")
        cfg.allowClosedLid = true
        cfg.closedLidStrategy = .privileged
        #expect(zh.startButtonTitle(for: cfg).contains("授权"))
        #expect(en.startButtonTitle(for: cfg).contains("Authorize"))

        #expect(zh.autoFollowCeilingLabel("12:00", sourceKind: .hookOnly) != zh.autoFollowCeilingLabel("12:00", sourceKind: .directoryOnly))
        #expect(!zh.autoFollowPolicySummary(.hookOnly).contains("停笔 5 分钟"))
        #expect(!en.autoFollowPolicySummary(.hookOnly).contains("5m idle"))
        #expect(zh.closedLidInlineNote(strategy: .unprivileged).contains("6–9"))
        #expect(en.closedLidInlineNote(strategy: .unprivileged).contains("6–9"))
    }

    @Test func autoFollowDoesNotOverrideAManualSession() throws {
        let caf = MockCaffeinateRunner()
        let (manager, defaults, suite) = try makeManager(caf: caf)
        defer { defaults.removePersistentDomain(forName: suite) }

        manager.setAutoFollowEnabled(true)
        manager.startConfiguredSession()
        #expect(manager.isRunning)
        let startsAfterManual = caf.startCount

        manager.handleAgentActivity(.active(agents: ["Claude Code"], lastActivity: Date()))
        #expect(caf.startCount == startsAfterManual, "a manual session must not be re-launched by auto-follow")
        #expect(!manager.isFollowingAgents)

        manager.handleAgentActivity(.inactive)
        #expect(manager.isRunning, "a manual session must survive agents going quiet")
    }

    @Test func autoFollowLimitSuppressesUntilAgentsGoQuiet() throws {
        let caf = MockCaffeinateRunner()
        let (manager, defaults, suite) = try makeManager(caf: caf)
        defer { defaults.removePersistentDomain(forName: suite) }

        manager.setAutoFollowEnabled(true)
        manager.handleAgentActivity(.active(agents: ["Claude Code"], lastActivity: Date()))
        #expect(manager.isRunning)

        manager.handleAutoFollowLimitReached()
        #expect(!manager.isRunning, "the ceiling must release the assertion")
        #expect(manager.autoFollowLimitReached)

        manager.handleAgentActivity(.active(agents: ["Claude Code"], lastActivity: Date()))
        #expect(!manager.isRunning, "the ceiling must hold until the agents go quiet")

        manager.handleAgentActivity(.inactive)
        manager.handleAgentActivity(.active(agents: ["Claude Code"], lastActivity: Date()))
        #expect(manager.isRunning)
    }

    @Test func stoppingDuringAuthorizationCancelsTheLaunch() throws {
        let caf = MockCaffeinateRunner()
        let bag = MockBackpackGuard()
        bag.deferEnableCompletion = true
        let (manager, defaults, suite) = try makeManager(caf: caf, bag: bag)
        defer { defaults.removePersistentDomain(forName: suite) }

        manager.setClosedLidStrategy(.privileged)
        manager.setAllowClosedLid(true)
        manager.startConfiguredSession()
        #expect(manager.isAuthorizing)
        #expect(bag.enableCalls == 1)

        manager.stopSession(reason: .manual)
        #expect(!manager.isAuthorizing)

        bag.finishPendingEnable()
        #expect(!manager.isRunning)
        #expect(caf.startCount == 0)
    }

    @Test func thermalProtectionAndSessionHistory() throws {
        let suiteName = "io.github.laiyongqiang.SleepSkip.thermal.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferencesStore(defaults: defaults)

        var clock = Date(timeIntervalSince1970: 2_500_000_000)
        let thermal = MockThermalMonitor()
        let notif = MockNotifier()
        let manager = SessionManager(
            store: store,
            caffeinateRunner: MockCaffeinateRunner(),
            backpackGuard: MockBackpackGuard(),
            powerMonitor: MockPowerMonitor(),
            thermalMonitor: thermal,
            screenLocker: MockScreenLocker(),
            notifier: notif,
            loginItem: MockLoginItem(),
            cliInstaller: MockCLIInstaller(),
            nowProvider: { clock },
            checkStaleSleepOnInit: false
        )

        #expect(manager.config.thermalCutoff == .critical)

        thermal.overheated = true
        manager.startConfiguredSession()
        #expect(!manager.isRunning)
        #expect(manager.errorMessage != nil)

        thermal.overheated = false
        manager.selectMode(.keepDisplay)
        manager.startConfiguredSession()
        #expect(manager.isRunning)

        clock = clock.addingTimeInterval(180)
        thermal.triggerHandler?()
        #expect(!manager.isRunning)
        #expect(notif.sent.count == 1)
        let entry = try #require(manager.history.first)
        #expect(entry.stopReasonCode == "overheated")
        #expect(Int(entry.endedAt.timeIntervalSince(entry.startedAt).rounded()) == 180)

        manager.setThermalCutoff(.serious)
        #expect(store.load().thermalCutoff == .serious)

        manager.clearHistory()
        #expect(manager.history.isEmpty)
        #expect(store.loadHistory().isEmpty)
    }

    @Test func cliInstallerUpdatesStatus() throws {
        let suiteName = "io.github.laiyongqiang.SleepSkip.cli.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let cli = MockCLIInstaller()
        let manager = SessionManager(
            store: PreferencesStore(defaults: defaults),
            caffeinateRunner: MockCaffeinateRunner(),
            backpackGuard: MockBackpackGuard(),
            powerMonitor: MockPowerMonitor(),
            thermalMonitor: MockThermalMonitor(),
            screenLocker: MockScreenLocker(),
            notifier: MockNotifier(),
            loginItem: MockLoginItem(),
            cliInstaller: cli,
            checkStaleSleepOnInit: false
        )

        #expect(manager.cliInstallStatus == .notInstalled)
        manager.installCLICommand()
        #expect(manager.cliInstallStatus == .installed(path: "/usr/local/bin/sleepskip"))
        #expect(!manager.isInstallingCLI)
    }

    @Test func expandedAgentsCLIStatusAndAssertionParser() throws {
        let configured = AgentSource.configured(
            homeDirectory: URL(fileURLWithPath: "/Users/example"),
            disabledSourceIDs: ["dsh"],
            customPaths: ["/tmp/custom-agent"]
        )
        #expect(
            configured.map(\.id) ==
            ["claude-code", "codex", "gemini-cli", "opencode", "custom:/tmp/custom-agent"]
        )
        let custom = try #require(configured.last)
        #expect(custom.matches(filePath: "/tmp/custom-agent/output.log"))
        #expect(!custom.matches(filePath: "/tmp/custom-agent/.DS_Store"))
        #expect(!custom.matches(filePath: "/tmp/custom-agent/.git/HEAD"))
        #expect(!custom.matches(filePath: "/tmp/custom-agent/node_modules/a.js"))
        #expect(!custom.matches(filePath: "/tmp/custom-agent/app.lock"))

        #expect(CLIParser.parse(arguments: ["SleepSkip", "status"]) == .status(json: false))
        #expect(CLIParser.parse(arguments: ["SleepSkip", "status", "--json"]) == .status(json: true))
        #expect(CLIParser.parse(arguments: ["SleepSkip", "stop"]) == .control(action: "stop"))
        #expect(CLIParser.parse(arguments: ["SleepSkip", "toggle"]) == .control(action: "toggle"))

        let parsed = PowerOutputParser.parseAssertions(fromPmsetOutput: """
           pid 101(caffeinate): [0x01] 00:05:00 PreventUserIdleSystemSleep named: "cli"
           pid 202(WindowServer): [0x02] 00:01:00 BackgroundTask named: "bg"
        """)
        #expect(parsed.count == 1)
        #expect(parsed.first?.processName == "caffeinate")
    }

    @Test func hookCLParsingAndMultiSessionRefcounting() throws {
        #expect(
            CLIParser.parse(arguments: ["SleepSkip", "hook", "start", "--agent", "claude-code", "--session", "s1", "--pid", "4321"]) ==
            .hook(action: .start, sessionID: "s1", agent: "claude-code", pid: 4321)
        )
        #expect(
            CLIParser.parse(arguments: ["SleepSkip", "hook", "stop"]) ==
            .hook(action: .stop, sessionID: nil, agent: "claude-code", pid: nil)
        )

        let caf = MockCaffeinateRunner()
        let (manager, defaults, suite) = try makeManager(caf: caf)
        defer { defaults.removePersistentDomain(forName: suite) }

        manager.setAutoFollowEnabled(true)
        manager.handleAgentActivity(.active(agents: ["Claude Code"], lastActivity: Date()))
        #expect(manager.isFollowingAgents)

        manager.handleHookStart(sessionID: "tab-1", agent: "claude-code")
        manager.handleHookStart(sessionID: "tab-2", agent: "codex")
        #expect(manager.hasActiveHookSessions)
        #expect(manager.followingAgents == ["Claude Code", "Codex"])

        // Ending tab-1 keeps tab-2 alive.
        manager.handleHookStop(sessionID: "tab-1", agent: "claude-code")
        #expect(manager.hasActiveHookSessions)
        #expect(manager.isRunning)
        #expect(manager.followingAgents == ["Codex"])

        // Ending the last hook session clears residual FSEvents window and releases right away.
        manager.handleHookStop(sessionID: "tab-2", agent: "codex")
        #expect(!manager.hasActiveHookSessions)
        #expect(!manager.isRunning)
        #expect(manager.history.first?.stopReasonCode == "hookStop")
    }

    @Test func claudeCodeHookManagerMergesAndRemovesSafely() throws {
        #expect(CLIParser.parse(arguments: ["SleepSkip", "hook", "install"]) == .hook(action: .install, sessionID: nil, agent: "claude-code", pid: nil))
        #expect(CLIParser.parse(arguments: ["SleepSkip", "hook", "uninstall"]) == .hook(action: .uninstall, sessionID: nil, agent: "claude-code", pid: nil))
        #expect(CLIParser.parse(arguments: ["SleepSkip", "doctor"]) == .doctor)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sleepskip-hook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let settingsURL = dir.appendingPathComponent("settings.json")
        let existing: [String: Any] = [
            "model": "sonnet",
            "hooks": [
                "UserPromptSubmit": [
                    ["hooks": [["type": "command", "command": "echo existing-hook"]]]
                ]
            ]
        ]
        let rawData = try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted])
        try rawData.write(to: settingsURL)

        let hookManager = ClaudeCodeHookManager(settingsURL: settingsURL)
        #expect(!hookManager.isConnected)

        try hookManager.connect()
        #expect(hookManager.isConnected)

        // Calling connect again must stay idempotent without duplicating entries.
        try hookManager.connect()
        let connectedObj = try #require(JSONSerialization.jsonObject(with: try Data(contentsOf: settingsURL)) as? [String: Any])
        #expect(connectedObj["model"] as? String == "sonnet")
        let connectedHooks = try #require(connectedObj["hooks"] as? [String: Any])
        let submitHooks = try #require(connectedHooks["UserPromptSubmit"] as? [[String: Any]])
        #expect(submitHooks.count == 2)

        try hookManager.disconnect()
        #expect(!hookManager.isConnected)

        // Existing user settings and hooks remain untouched after disconnect.
        let afterDisconnectObj = try #require(JSONSerialization.jsonObject(with: try Data(contentsOf: settingsURL)) as? [String: Any])
        #expect(afterDisconnectObj["model"] as? String == "sonnet")
        let remainingHooks = try #require(afterDisconnectObj["hooks"] as? [String: Any])
        let remainingSubmit = try #require(remainingHooks["UserPromptSubmit"] as? [[String: Any]])
        #expect(remainingSubmit.count == 1)
        #expect(remainingHooks["Stop"] == nil)
    }
    @Test func idleManualStopDoesNotSuppressTheNextDirectoryTask() throws {
        let (manager, defaults, suite) = try makeManager(caf: MockCaffeinateRunner())
        defer { defaults.removePersistentDomain(forName: suite) }
        manager.setAutoFollowEnabled(true)
        manager.startConfiguredSession()
        manager.stopSession()
        manager.agentTracker.recordActivity(sourceID: "Codex")
        manager.handleAgentActivity(manager.agentTracker.evaluate())
        #expect(manager.isFollowingAgents)
    }

    @Test func explicitConfiguredStartPromotesAutomaticSession() throws {
        let (manager, defaults, suite) = try makeManager(caf: MockCaffeinateRunner())
        defer { defaults.removePersistentDomain(forName: suite) }
        manager.setAutoFollowEnabled(true)
        manager.handleHookStart(sessionID: "s", agent: "codex")
        manager.startConfiguredSession()
        #expect(manager.isRunning)
        #expect(!manager.isFollowingAgents)
        manager.handleHookStop(sessionID: "s", agent: "codex")
        #expect(manager.isRunning)
        manager.handleAgentActivity(.inactive)
        #expect(manager.isRunning)
    }

    @Test func hookSessionIDsAreNamespacedByAgentAndPreserveSettings() throws {
        let (manager, defaults, suite) = try makeManager(caf: MockCaffeinateRunner())
        defer { defaults.removePersistentDomain(forName: suite) }
        manager.setAutoFollowEnabled(false)
        manager.handleHookStart(sessionID: "same", agent: "claude-code")
        manager.handleHookStart(sessionID: "same", agent: "codex")
        manager.handleHookStop(sessionID: "same", agent: "claude-code")
        #expect(manager.isRunning)
        #expect(manager.hasActiveHookSessions)
        #expect(manager.followingAgents == ["Codex"])
        #expect(!manager.config.autoFollowAgents)
    }

    @Test func hookFinishRetainsOtherSourcesIncludingGrace() throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let (manager, defaults, suite) = try makeManager(caf: MockCaffeinateRunner(), now: { now })
        defer { defaults.removePersistentDomain(forName: suite) }
        manager.setAutoFollowEnabled(true)
        manager.agentTracker.recordActivity(sourceID: "Claude Code")
        manager.agentTracker.recordActivity(sourceID: "Codex")
        manager.handleAgentActivity(manager.agentTracker.evaluate())
        manager.handleHookStart(sessionID: "s", agent: "claude-code")
        now = now.addingTimeInterval(45)
        manager.handleAgentActivity(manager.agentTracker.evaluate())
        manager.handleHookStop(sessionID: "s", agent: "claude-code")
        #expect(manager.isRunning)
        #expect(manager.agentTracker.evaluate().isHolding)
        #expect(manager.autoFollowGraceEndDate != nil)
        now = now.addingTimeInterval(300)
        manager.handleAgentActivity(manager.agentTracker.evaluate())
        #expect(!manager.isRunning)
    }

    @Test func automaticStartsUseTheSamePowerPreflightAsManualStarts() throws {
        let power = MockPowerMonitor()
        power.snapshot = PowerSnapshot(onBattery: true, percentage: 5)
        let notifier = MockNotifier()
        let (manager, defaults, suite) = try makeManager(caf: MockCaffeinateRunner(), notif: notifier, power: power)
        defer { defaults.removePersistentDomain(forName: suite) }
        manager.setAutoFollowEnabled(true)
        manager.setStopOnUnplug(false)
        manager.setBatteryThreshold(10)
        manager.handleAgentActivity(.active(agents: ["Codex"], lastActivity: Date()))
        #expect(!manager.isRunning)
        manager.setBatteryThreshold(0)
        manager.setStopOnUnplug(true)
        manager.handleHookStart(sessionID: "s", agent: "codex")
        #expect(!manager.isRunning)
        power.snapshot = PowerSnapshot(onBattery: false, percentage: 90)
        manager.handleHookStart(sessionID: "s", agent: "codex")
        #expect(manager.isRunning)
        #expect(notifier.prepareCount == 1)
    }

    @Test func urlStopCancelsAuthorizationAndLateSuccessCleansGuard() throws {
        let bag = MockBackpackGuard()
        bag.deferEnableCompletion = true
        let (manager, defaults, suite) = try makeManager(caf: MockCaffeinateRunner(), bag: bag)
        defer { defaults.removePersistentDomain(forName: suite) }
        manager.setClosedLidStrategy(.privileged)
        manager.setAllowClosedLid(true)
        manager.startConfiguredSession()
        manager.applyURLCommand(.stop)
        #expect(!manager.isAuthorizing)
        bag.finishPendingEnable()
        #expect(!manager.isRunning)
        #expect(!bag.enabled)
    }

    @Test func hookDisconnectPreservesEchoExamplesAndRejectsNonObjectHooks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ss-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let example = "echo 'sleepskip hook start --agent claude-code'"
        let settings: [String: Any] = ["hooks": ["UserPromptSubmit": [["hooks": [["type": "command", "command": example]]]]]]
        try JSONSerialization.data(withJSONObject: settings).write(to: url)
        let hooks = ClaudeCodeHookManager(settingsURL: url)
        try hooks.disconnect()
        let preserved = try String(contentsOf: url, encoding: .utf8)
        #expect(preserved.contains(example))
        try Data("{\"hooks\":\"user value\"}".utf8).write(to: url)
        #expect(throws: (any Error).self) { try hooks.connect() }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{\"hooks\":\"user value\"}")
    }

    @Test func hooksUseQuotedExecutableAndMigrateOnlyExactOwnedCommands() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ss-hooks-quote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("SleepSkip ' helper")
        let marker = directory.appendingPathComponent("called")
        try Data("#!/bin/sh\nprintf '%s:%s' \"$1\" \"$2\" > '\(marker.path)'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let url = directory.appendingPathComponent("settings.json")
        let example = "echo 'sleepskip hook start --agent claude-code'"
        let settings: [String: Any] = ["theme": "untouched", "hooks": [
            "UserPromptSubmit": [["hooks": [
                ["type": "command", "command": ClaudeCodeHookManager.startCommand],
                ["type": "command", "command": example]
            ]]],
            "Stop": [["hooks": [["type": "command", "command": ClaudeCodeHookManager.stopCommand]]]]
        ]]
        try JSONSerialization.data(withJSONObject: settings).write(to: url)
        let hooks = ClaudeCodeHookManager(settingsURL: url, executableURL: executable)
        #expect(!hooks.isConnected)
        try hooks.connect()
        #expect(hooks.isConnected)
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let all = try #require(root["hooks"] as? [String: Any])
        let entries = try #require(all["UserPromptSubmit"] as? [[String: Any]])
        let commands = entries.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { $0["command"] as? String }
        #expect(commands.count == 2)
        #expect(commands.contains(example))
        let installed = try #require(commands.first { $0 != example })
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", installed]
        try shell.run()
        shell.waitUntilExit()
        #expect(shell.terminationStatus == 0)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "hook:start")
        try hooks.disconnect()
        #expect(try String(contentsOf: url, encoding: .utf8).contains(example))
        let before = try Data(contentsOf: url)
        let invalid = ClaudeCodeHookManager(settingsURL: url, executableURL: directory.appendingPathComponent("missing"))
        #expect(throws: (any Error).self) { try invalid.connect() }
        #expect(!invalid.isConnected)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func automaticCeilingStaysSuppressedAcrossBusyWritesAndRecoversAfterQuiet() throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let (manager, defaults, suite) = try makeManager(caf: MockCaffeinateRunner(), now: { now })
        defer { defaults.removePersistentDomain(forName: suite) }
        manager.setAutoFollowEnabled(true)
        manager.agentTracker.recordActivity(sourceID: "codex")
        manager.handleAgentActivity(manager.agentTracker.evaluate())
        for _ in 0..<240 {
            now = now.addingTimeInterval(30)
            manager.agentTracker.recordActivity(sourceID: "codex")
        }
        manager.refreshDisplayTick()
        #expect(manager.autoFollowLimitReached)
        #expect(!manager.isRunning)
        manager.handleAgentActivity(manager.agentTracker.evaluate())
        #expect(!manager.isRunning)
        now = now.addingTimeInterval(331)
        manager.handleAgentActivity(manager.agentTracker.evaluate())
        manager.agentTracker.recordActivity(sourceID: "codex")
        manager.handleAgentActivity(manager.agentTracker.evaluate())
        #expect(manager.isFollowingAgents)
        #expect(manager.remainingSeconds == 7200)
        #expect(!manager.autoFollowLimitReached)
    }

    @Test func disablingDirectoryFollowKeepsExplicitHookProtection() throws {
        let (manager, defaults, suite) = try makeManager(caf: MockCaffeinateRunner())
        defer { defaults.removePersistentDomain(forName: suite) }
        manager.setAutoFollowEnabled(true)
        manager.agentTracker.recordActivity(sourceID: "codex")
        manager.handleAgentActivity(manager.agentTracker.evaluate())
        manager.handleHookStart(sessionID: "s", agent: "claude-code")
        manager.setAutoFollowEnabled(false)
        #expect(manager.isRunning)
        #expect(manager.followingAgents == ["Claude Code"])
        manager.handleHookStop(sessionID: "s", agent: "claude-code")
        #expect(!manager.isRunning)
    }

    @Test func busyManualStopSuppressesHookUntilMatchingFinish() throws {
        let (manager, defaults, suite) = try makeManager(caf: MockCaffeinateRunner())
        defer { defaults.removePersistentDomain(forName: suite) }
        manager.setAutoFollowEnabled(false)
        manager.handleHookStart(sessionID: "s", agent: "codex")
        manager.stopSession()
        manager.handleHookStart(sessionID: "s", agent: "codex")
        #expect(!manager.isRunning)
        manager.handleHookStop(sessionID: "s", agent: "codex")
        manager.handleHookStart(sessionID: "fresh", agent: "codex")
        #expect(manager.isFollowingAgents)
    }

    @Test func successfulDisplayModeSwitchReleasesClosedLidButFailedSwitchRetainsIt() throws {
        let caf = MockCaffeinateRunner()
        let bag = MockBackpackGuard()
        let (manager, defaults, suite) = try makeManager(caf: caf, bag: bag)
        defer { defaults.removePersistentDomain(forName: suite) }
        manager.setClosedLidStrategy(.privileged)
        manager.setAllowClosedLid(true)
        manager.startConfiguredSession()
        #expect(manager.activeClosedLid)
        let disables = bag.disableCalls
        caf.shouldThrowOnStart = true
        manager.switchRunningMode(to: .keepDisplay)
        #expect(manager.activeClosedLid)
        #expect(bag.disableCalls == disables)
        caf.shouldThrowOnStart = false
        manager.switchRunningMode(to: .keepDisplay)
        #expect(!manager.activeClosedLid)
        #expect(!bag.enabled)
        #expect(manager.config.allowClosedLid)
    }

    @Test func authorizationDeadlineRemains120SecondsAndCleansBeforeLateSuccess() throws {
        let bag = MockBackpackGuard()
        bag.deferEnableCompletion = true
        let suite = "ss.auth.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var scheduled: [(TimeInterval, () -> Void)] = []
        let manager = SessionManager(
            store: PreferencesStore(defaults: defaults),
            caffeinateRunner: MockCaffeinateRunner(), backpackGuard: bag,
            powerMonitor: MockPowerMonitor(), screenLocker: MockScreenLocker(),
            notifier: MockNotifier(), loginItem: MockLoginItem(), checkStaleSleepOnInit: false,
            authorizationScheduler: { delay, action in scheduled.append((delay, action)) }
        )
        manager.setClosedLidStrategy(.privileged)
        manager.setAllowClosedLid(true)
        manager.startConfiguredSession()
        #expect(scheduled.count == 1)
        #expect(scheduled.first?.0 == 120)
        let priorDisables = bag.disableCalls
        scheduled[0].1()
        #expect(!manager.isAuthorizing)
        #expect(bag.disableCalls > priorDisables)
        #expect(manager.errorMessage == manager.l10n.authorizationTimedOut)
        bag.finishPendingEnable()
        #expect(!manager.isRunning)
        #expect(!bag.enabled)
    }

    @Test func staleAuthorizationCannotCancelOrReleaseANewerAttempt() throws {
        let bag = MockBackpackGuard()
        bag.deferEnableCompletion = true
        let suite = "ss.auth-new.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var scheduled: [() -> Void] = []
        let manager = SessionManager(
            store: PreferencesStore(defaults: defaults),
            caffeinateRunner: MockCaffeinateRunner(), backpackGuard: bag,
            powerMonitor: MockPowerMonitor(), screenLocker: MockScreenLocker(),
            notifier: MockNotifier(), loginItem: MockLoginItem(), checkStaleSleepOnInit: false,
            authorizationScheduler: { _, action in scheduled.append(action) }
        )
        manager.setClosedLidStrategy(.privileged)
        manager.setAllowClosedLid(true)
        manager.startConfiguredSession()
        manager.stopSession()
        manager.startConfiguredSession()
        let disables = bag.disableCalls
        scheduled[0]()
        #expect(manager.isAuthorizing)
        bag.finishPendingEnable()
        #expect(manager.isAuthorizing)
        #expect(bag.disableCalls == disables)
        bag.finishPendingEnable()
        #expect(manager.isRunning)
        #expect(manager.activeClosedLid)
        #expect(bag.enabled)
    }

    @Test func disconnectWithoutOwnedHooksPreservesExactSettingsBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ss-hooks-none-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let original = Data("{ \"hooks\": {\"Stop\": [], \"UserPromptSubmit\": [{\"hooks\": []}]}, \"theme\": \"mine\" }".utf8)
        try original.write(to: url)
        try ClaudeCodeHookManager(settingsURL: url).disconnect()
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func hookOnlyCeilingRearmsAfterTheFinishedTask() throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let (manager, defaults, suite) = try makeManager(caf: MockCaffeinateRunner(), now: { now })
        defer { defaults.removePersistentDomain(forName: suite) }
        manager.setAutoFollowEnabled(false)
        manager.handleHookStart(sessionID: "s", agent: "codex")
        now = now.addingTimeInterval(7200)
        manager.refreshDisplayTick()
        #expect(!manager.isRunning)
        #expect(manager.autoFollowLimitReached)
        manager.handleHookStart(sessionID: "s", agent: "codex")
        #expect(!manager.isRunning)
        manager.handleHookStop(sessionID: "s", agent: "codex")
        manager.handleHookStart(sessionID: "next", agent: "codex")
        #expect(manager.isFollowingAgents)
        #expect(manager.remainingSeconds == 7200)
    }

    @Test func manualStopAfterUnreportedQuietDoesNotLoseTheNextTask() throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let (manager, defaults, suite) = try makeManager(caf: MockCaffeinateRunner(), now: { now })
        defer { defaults.removePersistentDomain(forName: suite) }
        manager.setAutoFollowEnabled(true)
        manager.agentTracker.recordActivity(sourceID: "codex")
        manager.handleAgentActivity(manager.agentTracker.evaluate())
        now = now.addingTimeInterval(331)
        manager.stopSession()
        manager.agentTracker.recordActivity(sourceID: "codex")
        manager.handleAgentActivity(manager.agentTracker.evaluate())
        #expect(manager.isFollowingAgents)
    }

    @Test func busyStopRecoversFromAQuietGapWithoutAnIntermediateInactiveCallback() throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let (manager, defaults, suite) = try makeManager(caf: MockCaffeinateRunner(), now: { now })
        defer { defaults.removePersistentDomain(forName: suite) }
        manager.setAutoFollowEnabled(true)
        manager.agentTracker.recordActivity(sourceID: "codex")
        manager.handleAgentActivity(manager.agentTracker.evaluate())
        manager.stopSession()
        now = now.addingTimeInterval(20)
        manager.agentTracker.recordActivity(sourceID: "codex")
        manager.handleAgentActivity(manager.agentTracker.evaluate())
        #expect(!manager.isRunning)
        now = now.addingTimeInterval(331)
        manager.agentTracker.recordActivity(sourceID: "codex")
        manager.handleAgentActivity(manager.agentTracker.evaluate())
        #expect(manager.isFollowingAgents)
    }

    @Test func expiredSuppressedHookLeaseCannotBlockAFreshTaskForever() throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let (manager, defaults, suite) = try makeManager(caf: MockCaffeinateRunner(), now: { now })
        defer { defaults.removePersistentDomain(forName: suite) }
        manager.setAutoFollowEnabled(false)
        manager.handleHookStart(sessionID: "old", agent: "codex")
        #expect(manager.nextHookLeaseExpirationDate == now.addingTimeInterval(7200))
        manager.stopSession()
        now = now.addingTimeInterval(7200)
        let expired = manager.expireHookLeases()
        #expect(expired.map(\.sessionID) == ["old"])
        #expect(!manager.hasActiveHookSessions)
        #expect(!manager.isRunning)
        manager.handleHookStart(sessionID: "fresh", agent: "codex")
        #expect(manager.isFollowingAgents)
    }

    @Test func hookLeaseExpiryPreservesRefreshedLeaseAndManualSession() throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let (manager, defaults, suite) = try makeManager(caf: MockCaffeinateRunner(), now: { now })
        defer { defaults.removePersistentDomain(forName: suite) }
        manager.setAutoFollowEnabled(false)
        manager.startConfiguredSession()
        manager.handleHookStart(sessionID: "old", agent: "claude-code")
        manager.handleHookStart(sessionID: "refresh", agent: "codex")
        now = now.addingTimeInterval(100)
        manager.handleHookStart(sessionID: "refresh", agent: "codex")
        now = now.addingTimeInterval(7100)
        let expired = manager.expireHookLeases()
        #expect(expired.map(\.sessionID) == ["old"])
        #expect(manager.isRunning)
        #expect(!manager.isFollowingAgents)
        #expect(manager.hasActiveHookSessions)
        #expect(manager.nextHookLeaseExpirationDate == now.addingTimeInterval(100))
        now = now.addingTimeInterval(100)
        manager.expireHookLeases()
        #expect(!manager.hasActiveHookSessions)
        #expect(manager.isRunning)
    }

    @Test func repeatedAgentWritesPublishOnlyVisibleChanges() throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let (manager, defaults, suite) = try makeManager(caf: MockCaffeinateRunner(), now: { now })
        defer { defaults.removePersistentDomain(forName: suite) }
        manager.setAutoFollowEnabled(true)
        manager.agentTracker.recordActivity(sourceID: "codex")
        manager.handleAgentActivity(manager.agentTracker.evaluate())
        var changes = 0
        let observation = manager.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        manager.agentTracker.recordActivity(sourceID: "codex")
        manager.handleAgentActivity(manager.agentTracker.evaluate())
        #expect(changes == 0)
        now = now.addingTimeInterval(1)
        manager.agentTracker.recordActivity(sourceID: "codex")
        manager.handleAgentActivity(manager.agentTracker.evaluate())
        #expect(changes == 1)
        #expect(manager.remainingSeconds == 7199)
    }

    @Test func wakeAndProcessExitAfterTheAutomaticDeadlineCannotBypassTheCeiling() throws {
        for reconcileWake in [true, false] {
            var now = Date(timeIntervalSince1970: 1_700_000_000)
            let caf = MockCaffeinateRunner()
            let (manager, defaults, suite) = try makeManager(caf: caf, now: { now })
            defer { defaults.removePersistentDomain(forName: suite) }
            manager.setAutoFollowEnabled(false)
            manager.handleHookStart(sessionID: "busy", agent: "codex")
            now = now.addingTimeInterval(7200)
            caf.isActive = false
            if reconcileWake { manager.reconcileOnWakeOrShow() }
            else { caf.exitCallback?() }
            #expect(!manager.isRunning)
            #expect(manager.autoFollowLimitReached)
            manager.handleHookStart(sessionID: "busy", agent: "codex")
            #expect(!manager.isRunning)
        }
    }

    @Test func delayedAuthorizationRechecksBatteryBeforeAssertionAndLock() throws {
        for stopOnUnplug in [true, false] {
            let caf = MockCaffeinateRunner()
            let bag = MockBackpackGuard()
            let power = MockPowerMonitor()
            let locker = MockScreenLocker()
            bag.deferEnableCompletion = true
            let (manager, defaults, suite) = try makeManager(caf: caf, bag: bag, power: power, locker: locker)
            defer { defaults.removePersistentDomain(forName: suite) }
            manager.setClosedLidStrategy(.privileged)
            manager.setAllowClosedLid(true)
            manager.setLockOnStart(true)
            manager.setStopOnUnplug(stopOnUnplug)
            manager.setBatteryThreshold(10)
            manager.startConfiguredSession()
            #expect(manager.isAuthorizing)
            power.snapshot = PowerSnapshot(onBattery: true, percentage: stopOnUnplug ? 90 : 5)
            bag.finishPendingEnable()
            #expect(!manager.isRunning)
            #expect(!manager.isAuthorizing)
            #expect(!bag.enabled)
            #expect(caf.startCount == 0)
            #expect(locker.lockCount == 0)
            #expect(manager.errorMessage == (stopOnUnplug
                ? manager.l10n.unpluggedBlockedError
                : manager.l10n.lowBatteryBlockedError(current: 5, threshold: 10)))
        }
    }

    @Test func delayedAuthorizationRechecksThermalsBeforeAssertionAndLock() throws {
        let caf = MockCaffeinateRunner()
        let bag = MockBackpackGuard()
        let thermal = MockThermalMonitor()
        let locker = MockScreenLocker()
        bag.deferEnableCompletion = true
        let (manager, defaults, suite) = try makeManager(caf: caf, bag: bag, thermal: thermal, locker: locker)
        defer { defaults.removePersistentDomain(forName: suite) }
        manager.setClosedLidStrategy(.privileged)
        manager.setAllowClosedLid(true)
        manager.setLockOnStart(true)
        manager.setThermalCutoff(.serious)
        manager.startConfiguredSession()
        #expect(manager.isAuthorizing)
        thermal.overheated = true
        bag.finishPendingEnable()
        #expect(!manager.isRunning)
        #expect(!bag.enabled)
        #expect(caf.startCount == 0)
        #expect(locker.lockCount == 0)
        #expect(manager.errorMessage == manager.l10n.overheatedBlockedError)
    }

    @Test func rejectedAuthorizedReplacementPreservesTheRunningManualAssertion() throws {
        let caf = MockCaffeinateRunner()
        let bag = MockBackpackGuard()
        let power = MockPowerMonitor()
        let locker = MockScreenLocker()
        let (manager, defaults, suite) = try makeManager(caf: caf, bag: bag, power: power, locker: locker)
        defer { defaults.removePersistentDomain(forName: suite) }
        manager.setStopOnUnplug(true)
        manager.startConfiguredSession()
        let originalEnd = manager.endDate
        let originalMode = manager.activeMode
        let starts = caf.startCount
        let stops = caf.stopCount
        let locks = locker.lockCount
        bag.deferEnableCompletion = true
        manager.setClosedLidStrategy(.privileged)
        manager.setAllowClosedLid(true)
        manager.setLockOnStart(true)
        manager.selectDuration(90)
        manager.startConfiguredSession()
        power.snapshot = PowerSnapshot(onBattery: true, percentage: 90)
        bag.finishPendingEnable()
        #expect(manager.isRunning)
        #expect(caf.isActive)
        #expect(manager.activeMode == originalMode)
        #expect(manager.endDate == originalEnd)
        #expect(!manager.activeClosedLid)
        #expect(!bag.enabled)
        #expect(caf.startCount == starts)
        #expect(caf.stopCount == stops)
        #expect(locker.lockCount == locks)
        #expect(manager.history.isEmpty)
    }

    @Test func hookExpiryCannotEraseBusyTranscriptOrBypassTheAutomaticCeiling() throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let (manager, defaults, suite) = try makeManager(caf: MockCaffeinateRunner(), now: { now })
        defer { defaults.removePersistentDomain(forName: suite) }
        manager.setAutoFollowEnabled(true)
        manager.handleHookStart(sessionID: "s", agent: "codex")
        manager.agentTracker.recordActivity(sourceID: "codex")
        manager.handleAgentActivity(manager.agentTracker.evaluate())
        now = now.addingTimeInterval(7199)
        manager.agentTracker.recordActivity(sourceID: "codex")
        manager.handleAgentActivity(manager.agentTracker.evaluate())
        now = now.addingTimeInterval(1)
        manager.handleAutoFollowLimitReached()
        manager.expireHookLeases()
        #expect(!manager.hasActiveHookSessions)
        #expect(manager.agentTracker.holdingSourceIDs == ["codex"])
        #expect(!manager.isRunning)
        now = now.addingTimeInterval(1)
        manager.agentTracker.recordActivity(sourceID: "codex")
        manager.handleAgentActivity(manager.agentTracker.evaluate())
        #expect(!manager.isRunning)
        now = now.addingTimeInterval(331)
        manager.handleAgentActivity(manager.agentTracker.evaluate())
        manager.agentTracker.recordActivity(sourceID: "codex")
        manager.handleAgentActivity(manager.agentTracker.evaluate())
        #expect(manager.isFollowingAgents)
    }

    @Test func automaticQuietDoesNotCancelThePendingExplicitManualAuthorization() throws {
        for hookOnly in [false, true] {
            let caf = MockCaffeinateRunner()
            let bag = MockBackpackGuard()
            let (manager, defaults, suite) = try makeManager(caf: caf, bag: bag)
            defer { defaults.removePersistentDomain(forName: suite) }
            manager.setAutoFollowEnabled(!hookOnly)
            manager.setLockOnStart(false)
            if hookOnly { manager.handleHookStart(sessionID: "s", agent: "codex") }
            else { manager.handleAgentActivity(.active(agents: ["Codex"], lastActivity: Date())) }
            #expect(manager.isFollowingAgents)
            bag.deferEnableCompletion = true
            manager.setClosedLidStrategy(.privileged)
            manager.setAllowClosedLid(true)
            manager.startConfiguredSession()
            #expect(manager.isAuthorizing)
            let disables = bag.disableCalls
            if hookOnly { manager.handleHookStop(sessionID: "s", agent: "codex") }
            else { manager.handleAgentActivity(.inactive) }
            #expect(!manager.isRunning)
            #expect(!caf.isActive)
            #expect(manager.isAuthorizing)
            #expect(bag.disableCalls == disables)
            bag.finishPendingEnable()
            #expect(manager.isRunning)
            #expect(!manager.isFollowingAgents)
            #expect(manager.activeClosedLid)
            #expect(bag.enabled)
            manager.handleAgentActivity(.inactive)
            #expect(manager.isRunning)
        }
    }

    @Test func explicitStopAndSafetyEventsStillCancelAuthorizationAfterAutomaticQuiet() throws {
        for event in 0..<3 {
            let bag = MockBackpackGuard()
            let power = MockPowerMonitor()
            let thermal = MockThermalMonitor()
            let (manager, defaults, suite) = try makeManager(caf: MockCaffeinateRunner(), bag: bag, power: power, thermal: thermal)
            defer { defaults.removePersistentDomain(forName: suite) }
            manager.setAutoFollowEnabled(false)
            manager.handleHookStart(sessionID: "s", agent: "codex")
            bag.deferEnableCompletion = true
            manager.setClosedLidStrategy(.privileged)
            manager.setAllowClosedLid(true)
            manager.startConfiguredSession()
            manager.handleHookStop(sessionID: "s", agent: "codex")
            #expect(manager.isAuthorizing)
            switch event {
            case 0: manager.applyURLCommand(.stop)
            case 1: power.eventHandler?(.lowBattery(5))
            default: thermal.triggerHandler?()
            }
            #expect(!manager.isAuthorizing)
            bag.finishPendingEnable()
            #expect(!manager.isRunning)
            #expect(!bag.enabled)
            #expect(power.eventHandler == nil)
            #expect(thermal.triggerHandler == nil)
        }
    }

    @Test func failedManualAuthorizationAfterAutomaticQuietStopsIdleSafetyWatches() throws {
        let bag = MockBackpackGuard()
        let power = MockPowerMonitor()
        let thermal = MockThermalMonitor()
        let (manager, defaults, suite) = try makeManager(caf: MockCaffeinateRunner(), bag: bag, power: power, thermal: thermal)
        defer { defaults.removePersistentDomain(forName: suite) }
        manager.setAutoFollowEnabled(false)
        manager.handleHookStart(sessionID: "s", agent: "codex")
        bag.deferEnableCompletion = true
        manager.setClosedLidStrategy(.privileged)
        manager.setAllowClosedLid(true)
        manager.startConfiguredSession()
        manager.handleHookStop(sessionID: "s", agent: "codex")
        #expect(manager.isAuthorizing)
        bag.shouldFailEnable = true
        bag.finishPendingEnable()
        #expect(!manager.isAuthorizing)
        #expect(!manager.isRunning)
        #expect(power.eventHandler == nil)
        #expect(thermal.triggerHandler == nil)
    }

    @Test func closedLidManualToAutoFollowRequiresConfirmationAndPreservesProtectionOnCancelOrFailure() throws {
        final class MockLidGuard: ClosedLidGuarding {
            var isEngaged = false
            var disableCalls = 0
            func enable(completion: @escaping (Result<Void, Error>) -> Void) {
                isEngaged = true
                completion(.success(()))
            }
            func disable() {
                disableCalls += 1
                isEngaged = false
            }
        }

        // 1. Ordinary manual session switches immediately without confirmation.
        do {
            let caf = MockCaffeinateRunner()
            let (manager, defaults, suite) = try makeManager(caf: caf)
            defer { defaults.removePersistentDomain(forName: suite) }
            manager.setAutoFollowEnabled(true)
            manager.agentTracker.recordActivity(sourceID: "codex")
            manager.handleAgentActivity(manager.agentTracker.evaluate())
            manager.promoteAutoFollowToManual()
            #expect(!manager.activeClosedLid)
            manager.requestSwitchManualToAutoFollow()
            #expect(!manager.pendingAutoFollowSwitchConfirmation)
            #expect(manager.isFollowingAgents)
        }

        // 2. Standard (unprivileged) and Compatibility (privileged) closed-lid sessions require confirmation
        // and preserve lid protection on cancel or caffeinate failure.
        for strategy in [ClosedLidStrategy.unprivileged, ClosedLidStrategy.privileged] {
            let caf = MockCaffeinateRunner()
            let bag = MockBackpackGuard()
            let lid = MockLidGuard()
            let suite = "ss.lidswitch.\(strategy.rawValue).\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let manager = SessionManager(
                store: PreferencesStore(defaults: defaults),
                caffeinateRunner: caf,
                backpackGuard: bag,
                unprivilegedLidGuard: lid,
                powerMonitor: MockPowerMonitor(),
                screenLocker: MockScreenLocker(),
                notifier: MockNotifier(),
                loginItem: MockLoginItem(),
                checkStaleSleepOnInit: false
            )
            manager.setAutoFollowEnabled(true)
            manager.agentTracker.recordActivity(sourceID: "codex")
            manager.setClosedLidStrategy(strategy)
            manager.setAllowClosedLid(true)
            manager.startConfiguredSession()
            #expect(manager.isRunning && manager.activeClosedLid)
            #expect(manager.canSwitchToAutoFollow)
            let isProtected: () -> Bool = { strategy == .unprivileged ? lid.isEngaged : bag.enabled }
            #expect(isProtected())

            // Request stages confirmation without dropping protection.
            manager.requestSwitchManualToAutoFollow()
            #expect(manager.pendingAutoFollowSwitchConfirmation)
            #expect(manager.activeClosedLid)
            #expect(!manager.isFollowingAgents)
            #expect(isProtected())

            // Cancel preserves active closed-lid guard.
            manager.cancelSwitchToAutoFollow()
            #expect(!manager.pendingAutoFollowSwitchConfirmation)
            #expect(manager.activeClosedLid)
            #expect(isProtected())

            // Failure when starting auto-follow caffeinate preserves active closed-lid guard.
            manager.requestSwitchManualToAutoFollow()
            caf.shouldThrowOnStart = true
            manager.switchManualToAutoFollow()
            #expect(manager.errorMessage != nil)
            #expect(manager.activeClosedLid)
            #expect(!manager.isFollowingAgents)
            #expect(isProtected())

            // Confirmed switch succeeds and cleanly disables lid protection.
            caf.shouldThrowOnStart = false
            manager.requestSwitchManualToAutoFollow()
            manager.switchManualToAutoFollow()
            #expect(manager.isFollowingAgents)
            #expect(!manager.activeClosedLid)
            #expect(!manager.pendingAutoFollowSwitchConfirmation)
            #expect(!isProtected())
        }
    }

    @Test func hookProtectionStatusTracksOwnershipAcrossPauseLimitManualAndMultiSource() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let caf = MockCaffeinateRunner()
        let (manager, defaults, suite) = try makeManager(caf: caf, now: { now })
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(manager.hookProtectionStatus == .none)

        // Hook-only active -> holding
        manager.setAutoFollowEnabled(false)
        manager.handleHookStart(sessionID: "h1", agent: "claude-code")
        #expect(manager.hasActiveHookSessions)
        #expect(manager.hookProtectionStatus == .holding)

        // Manual stop -> lease stays for recovery, status accurately reports paused
        manager.stopSession(reason: .manual)
        #expect(manager.hasActiveHookSessions)
        #expect(manager.autoFollowSuppressed)
        #expect(manager.hookProtectionStatus == .paused(limitReached: false))

        // Resume -> holding again
        manager.resumeAutoFollow()
        #expect(manager.hookProtectionStatus == .holding)

        // 2h limit -> paused with limitReached = true
        manager.handleAutoFollowLimitReached()
        #expect(manager.hasActiveHookSessions)
        #expect(manager.hookProtectionStatus == .paused(limitReached: true))

        // Resume -> holding; then manual start takes ownership -> standbyBehindManual
        manager.resumeAutoFollow()
        #expect(manager.hookProtectionStatus == .holding)
        manager.startConfiguredSession()
        #expect(manager.isRunning && !manager.isFollowingAgents)
        #expect(manager.hookProtectionStatus == .standbyBehindManual)

        // Stop manual -> resumes paused state while hook lease still exists; hookStop clears to .none
        manager.stopSession(reason: .manual)
        #expect(manager.hookProtectionStatus == .paused(limitReached: false))
        manager.handleHookStop(sessionID: "h1", agent: "claude-code")
        #expect(manager.hookProtectionStatus == .none)

        // Multi-source (directory + hook): hookStop drops hook status to .none while directory keeps auto-follow alive
        manager.setAutoFollowEnabled(true)
        manager.agentTracker.recordActivity(sourceID: "codex")
        manager.handleAgentActivity(manager.agentTracker.evaluate())
        manager.handleHookStart(sessionID: "h2", agent: "claude-code")
        #expect(manager.hookProtectionStatus == .holding)
        manager.handleHookStop(sessionID: "h2", agent: "claude-code")
        #expect(manager.hookProtectionStatus == .none)
        #expect(manager.isFollowingAgents && manager.isRunning)

        // Copy check: paused badge must never say Holding / 保持中
        let zh = L10n(language: .zhHans)
        let en = L10n(language: .en)
        #expect(zh.claudeHookStatusBadge(.paused(limitReached: false)) == "已暂停")
        #expect(en.claudeHookStatusBadge(.paused(limitReached: false)) == "Paused")
        #expect(zh.returnToAutoFollowButton(dropsClosedLid: true).contains("合盖"))
        #expect(en.returnToAutoFollowButton(dropsClosedLid: true).contains("lid"))
    }

}
