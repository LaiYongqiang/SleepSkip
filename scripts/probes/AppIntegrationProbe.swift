import Cocoa
import CoreServices
import Foundation
import SleepSkipCore

final class ProbeStates: @unchecked Sendable {
    let lock = NSLock()
    var values: [AgentActivityState] = []
    func append(_ state: AgentActivityState) { lock.lock(); values.append(state); lock.unlock() }
    var activeCount: Int { lock.lock(); defer { lock.unlock() }; return values.filter { if case .active = $0 { return true }; return false }.count }
    var inactiveCount: Int { lock.lock(); defer { lock.unlock() }; return values.filter { if case .inactive = $0 { return true }; return false }.count }
}

@main enum AppIntegrationProbe {
    static func pause(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func serializedGuardProbe(_ root: URL) throws {
        let dir = root.appendingPathComponent("ordering ' files")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("changes.log")
        let flag = dir.appendingPathComponent("flag")
        let fakePmset = dir.appendingPathComponent("fake-power")
        let fakeWait = dir.appendingPathComponent("fake-wait")
        let powerBody = "#!/bin/sh\nprintf '%s\\n' \"$3\" >> \(CommandBuilder.shellSingleQuoted(log.path))\nif [ \"$3\" = 0 ]; then /bin/sleep 0.5; fi\nprintf '%s' \"$3\" > \(CommandBuilder.shellSingleQuoted(flag.path))\n"
        let waitBody = "#!/bin/sh\nwhile /bin/kill -0 \"$3\" 2>/dev/null; do /bin/sleep 0.05; done\n"
        try powerBody.write(to: fakePmset, atomically: true, encoding: .utf8)
        try waitBody.write(to: fakeWait, atomically: true, encoding: .utf8)
        for file in [fakePmset, fakeWait] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path) }
        func sentinel() throws -> (Process, Pipe) {
            let pipe = Pipe(); let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/cat")
            process.standardInput = pipe; process.standardOutput = FileHandle.nullDevice; try process.run()
            return (process, pipe)
        }
        func launch(_ sentinel: Process, name: String) throws -> URL {
            let script = dir.appendingPathComponent(name + ".sh")
            let ready = script.appendingPathExtension("ready")
            let body = BackpackGuard.watchScript(watchPID: sentinel.processIdentifier, readyURL: ready,
                powerCommand: fakePmset.path, waitCommand: fakeWait.path)
            require(!body.contains("/usr/bin/pmset") && !body.contains("/usr/bin/caffeinate"), "guard ordering probe must use fake system executables")
            try body.write(to: script, atomically: true, encoding: .utf8)
            let launcher = Process(); launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
            launcher.arguments = ["-c", BackpackGuard.serializedLaunchCommand(scriptURL: script, pidURL: script.appendingPathExtension("pid"), lockURL: dir.appendingPathComponent("guard.lock"))]
            try launcher.run(); launcher.waitUntilExit(); require(launcher.terminationStatus == 0, "fake guard launcher must succeed")
            return ready
        }
        func waitFor(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !condition(), Date() < deadline { pause(0.03) }
            require(condition(), "fake guard readiness/cleanup must finish")
        }
        let (a, pipeA) = try sentinel()
        let (b, pipeB) = try sentinel()
        defer { try? pipeA.fileHandleForWriting.close(); try? pipeB.fileHandleForWriting.close(); if a.isRunning { a.terminate() }; if b.isRunning { b.terminate() } }
        let readyA = try launch(a, name: "a")
        waitFor { FileManager.default.fileExists(atPath: readyA.path) }
        try pipeA.fileHandleForWriting.close(); if a.isRunning { a.terminate() }
        let readyB = try launch(b, name: "b")
        pause(0.15)
        require(!FileManager.default.fileExists(atPath: readyB.path), "replacement guard must stay unready while predecessor restores shared flag")
        waitFor { FileManager.default.fileExists(atPath: readyB.path) }
        let changes = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        require(changes == ["1", "0", "1"], "full-lifetime lock must order old restore before new enable")
        let heldFlag = try String(contentsOf: flag, encoding: .utf8)
        require(heldFlag == "1", "replacement ready guard must hold fake flag")
        try pipeB.fileHandleForWriting.close(); if b.isRunning { b.terminate() }
        waitFor { (try? String(contentsOf: flag, encoding: .utf8)) == "0" }
        print("PASS: actual guard scripts serialize fake power changes and per-attempt readiness")
    }

    static func main() throws {
        var flagCalls: [Bool] = []
        do { let guardObject = UnprivilegedLidGuard(setSuppressed: { flagCalls.append($0); return true }); guardObject.disable() }
        require(flagCalls.isEmpty, "inactive lid guard disable/deinit must not clear another owner's flag")
        do {
            let guardObject = UnprivilegedLidGuard(setSuppressed: { flagCalls.append($0); return true })
            guardObject.enable { _ in }; guardObject.disable(); guardObject.disable()
        }
        require(flagCalls == [true, false], "engaged lid guard clears its flag exactly once")

        let delegate = AppDelegate()
        delegate.application(NSApplication.shared, open: [URL(string: "sleepskip://toggle")!])
        _ = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        let beforeManager = Mirror(reflecting: delegate).children.first { $0.label?.contains("sessionManager") == true }
        require(beforeManager.map { Mirror(reflecting: $0.value).children.isEmpty } ?? true,
                "unowned/duplicate termination must not construct SessionManager")
        let manager = delegate.sessionManager
        let nativeResources = ["caffeinateRunner", "backpackGuard", "unprivilegedLidGuard", "powerMonitor", "thermalMonitor", "screenLocker", "notifier", "loginItem", "cliInstaller", "claudeHookController"]
        for field in Mirror(reflecting: manager).children where nativeResources.contains(field.label ?? "") {
            let value = Mirror(reflecting: field.value).displayStyle == .optional ? (Mirror(reflecting: field.value).children.first?.value as Any) : field.value
            require(value is IsolatedSystemServices, "isolated dependency \(field.label ?? "") must be inert")
        }
        let a = Process(); a.executableURL = URL(fileURLWithPath: "/bin/sleep"); a.arguments = ["30"]; try a.run()
        let b = Process(); b.executableURL = URL(fileURLWithPath: "/bin/sleep"); b.arguments = ["30"]; try b.run()
        defer { if a.isRunning { a.terminate() }; if b.isRunning { b.terminate() } }
        func deliver(_ selector: String, pid: Int32) {
            _ = delegate.perform(NSSelectorFromString(selector), with: Notification(name: IPCNotifications.cliStarted, userInfo: ["pid": NSNumber(value: pid), "cmd": "probe"]) as NSNotification)
            pause(0.1)
        }
        deliver("handleCLIStarted:", pid: a.processIdentifier)
        deliver("handleCLIStarted:", pid: b.processIdentifier)
        require(manager.externalCLI?.pid == a.processIdentifier, "second CLI must not replace stable first representative")
        deliver("handleCLIStopped:", pid: a.processIdentifier)
        require(manager.externalCLI?.pid == b.processIdentifier, "stopping A must retain B")
        deliver("handleCLIStopped:", pid: a.processIdentifier)
        require(manager.externalCLI?.pid == b.processIdentifier, "stale A stop must not clear B")
        b.terminate(); pause(0.3)
        require(manager.externalCLI == nil, "B process exit must clear final representative")

        delegate.configureSessionCallbacks()
        let hookA = Process(); hookA.executableURL = URL(fileURLWithPath: "/bin/sleep"); hookA.arguments = ["30"]; try hookA.run()
        let hookB = Process(); hookB.executableURL = URL(fileURLWithPath: "/bin/sleep"); hookB.arguments = ["30"]; try hookB.run()
        defer { if hookA.isRunning { hookA.terminate() }; if hookB.isRunning { hookB.terminate() } }
        func hook(_ action: String, agent: String, pid: Int32) {
            _ = delegate.perform(NSSelectorFromString("handleHookEvent:"), with: Notification(name: IPCNotifications.hookEvent,
                userInfo: ["action": action, "agent": agent, "sessionID": "same-session", "pid": NSNumber(value: pid)]) as NSNotification)
            pause(0.1)
        }
        hook("start", agent: "claude-code", pid: hookA.processIdentifier)
        hook("start", agent: "codex", pid: hookB.processIdentifier)
        require(manager.hasActiveHookSessions, "hook starts must create active leases")
        hook("stop", agent: "claude-code", pid: hookA.processIdentifier)
        require(manager.hasActiveHookSessions, "same session ID stop must retain other agent lease")
        manager.stopSession(reason: .manual)
        hookB.terminate(); pause(0.3)
        require(!manager.hasActiveHookSessions, "manual stop must retain PID watcher until hooked process exits")

        manager.agentTracker.reset(); manager.handleAgentActivity(.inactive)
        manager.agentTracker.recordActivity(sourceID: "probe")
        manager.handleAgentActivity(manager.agentTracker.evaluate())
        require(manager.isFollowingAgents && manager.isRunning, "directory activity must begin automatic session")
        manager.endDate = Date().addingTimeInterval(0.2)
        manager.onStateChange?(true, false)
        pause(0.4)
        require(!manager.isRunning && manager.autoFollowLimitReached, "directory-only automatic session must end at scheduled ceiling without next transcript write")

        manager.agentTracker.reset(); manager.handleAgentActivity(.inactive)
        manager.agentTracker.recordActivity(sourceID: "probe")
        manager.handleAgentActivity(manager.agentTracker.evaluate())
        hook("start", agent: "claude-code", pid: hookA.processIdentifier)
        manager.endDate = Date().addingTimeInterval(0.25)
        manager.onStateChange?(true, false)
        hook("stop", agent: "claude-code", pid: hookA.processIdentifier)
        require(manager.isRunning && manager.isFollowingAgents, "last hook stop must retain independent busy directory activity")
        pause(0.35)
        require(!manager.isRunning && manager.autoFollowLimitReached, "last hook stop must retain remaining directory ceiling timer")

        let authRoot = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("sleepskip-authorization-probe-\(UUID())")
        defer { try? FileManager.default.removeItem(at: authRoot) }
        try serializedGuardProbe(authRoot)
        var ready = false
        var unreadyResult: Result<Void, Error>?
        let unready = BackpackGuard(storageDirectory: authRoot, authorization: { _, cb in cb(.success(())) }, sleepChecker: { $0(true) }, readinessChecker: { _ in ready })
        unready.enable { unreadyResult = $0 }
        require(unreadyResult == nil, "global flag from predecessor must not report this attempt ready")
        ready = true; pause(0.25)
        require(unreadyResult != nil, "own readiness and verified flag must complete authorization")
        unready.disable()
        var callbacks: [(Result<Void, Error>) -> Void] = []
        let backpack = BackpackGuard(storageDirectory: authRoot, authorization: { _, completion in callbacks.append(completion) }, sleepChecker: { $0(true) }, readinessChecker: { _ in true })
        var firstResult: Result<Void, Error>?
        var secondResult: Result<Void, Error>?
        backpack.enable { firstResult = $0 }
        backpack.disable()
        backpack.enable { secondResult = $0 }
        callbacks[0](.failure(NSError(domain: "probe", code: 1)))
        require(backpack.isActive, "stale authorization failure must not stop new sentinel")
        callbacks[1](.success(()))
        require(backpack.isActive && secondResult != nil, "new authorization must remain active")
        require(firstResult != nil, "cancelled authorization must complete")
        backpack.disable()
        backpack.enable { _ in }
        backpack.disable()
        backpack.enable { _ in }
        callbacks[2](.success(()))
        require(backpack.isActive, "stale authorization success must not stop new sentinel")
        backpack.disable()
        var delayedReadback: ((Bool) -> Void)?
        var delayedAuth: [(Result<Void, Error>) -> Void] = []
        let verifying = BackpackGuard(storageDirectory: authRoot, authorization: { _, cb in delayedAuth.append(cb) }, sleepChecker: { delayedReadback = $0 }, readinessChecker: { _ in true })
        verifying.enable { _ in }; delayedAuth[0](.success(()))
        verifying.disable(); verifying.enable { _ in }
        delayedReadback?(true)
        require(verifying.isActive, "stale readback must not terminate the new sentinel")
        verifying.disable()
        print("PASS: inert isolated dependencies, duplicate teardown, concurrent CLI registry, asynchronous authorization ownership, lid flag ownership")

        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("sleepskip-monitor-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = AgentSource(id: "probe", displayName: "Probe", path: root.path)
        let states = ProbeStates()
        let monitor = AgentActivityMonitor(tracker: AgentActivityTracker(policy: .init(activityWindow: 4, gracePeriod: 0.1)), onStateChange: states.append)
        monitor.start(sources: [source])
        require(monitor.isRunning, "FSEvents unavailable: run this temporary-file probe with normal local event access")
        pause(0.5)
        let file = root.appendingPathComponent("run.jsonl")
        try Data("one".utf8).write(to: file)
        pause(1)
        require(states.activeCount > 0, "real creation must report activity")
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data("two".utf8)); try handle.close()
        pause(1)
        require(states.activeCount >= 2, "ongoing transcript writes must still reach manager after hook stop")
        let beforeAtomic = states.activeCount
        try Data("atomic replacement".utf8).write(to: file, options: .atomic)
        pause(1)
        require(states.activeCount > beforeAtomic, "atomic transcript replacement must count as activity")
        let beforeMetadata = states.activeCount
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        pause(1)
        require(states.activeCount == beforeMetadata, "metadata-only changes must not count as activity")
        let beforeRemoval = states.activeCount
        try FileManager.default.removeItem(at: file)
        pause(1)
        require(states.activeCount == beforeRemoval, "removed transcript must not record activity")
        monitor.stop()

        let absent = root.appendingPathComponent("not-yet/nested")
        let discovered = ProbeStates()
        let late = AgentActivityMonitor(tracker: AgentActivityTracker(), onStateChange: discovered.append)
        late.start(sources: [AgentSource(id: "late", displayName: "Late", path: absent.path)])
        pause(0.5)
        try FileManager.default.createDirectory(at: absent, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: absent.appendingPathComponent("run.jsonl"))
        pause(1.5)
        require(discovered.activeCount > 0, "new source directory must be discovered without polling or panel reopen")
        late.stop()
        let cappedStates = ProbeStates()
        let capTracker = AgentActivityTracker(policy: .init(activityWindow: 0.4, gracePeriod: 0.2, maxAutoSessionDuration: 0.1))
        let capMonitor = AgentActivityMonitor(tracker: capTracker, onStateChange: cappedStates.append)
        capMonitor.start(sources: [source]); pause(0.4)
        try Data("capped".utf8).write(to: file)
        pause(0.25)
        require(capTracker.autoSessionExceeded(), "session cap must be recorded by tracker")
        pause(1.25)
        require(cappedStates.inactiveCount > 0, "session cap must preserve quiet timer through inactivity")
        capMonitor.stop()
        weak var releasedMonitor: AgentActivityMonitor?
        do {
            var temporary: AgentActivityMonitor? = AgentActivityMonitor(tracker: AgentActivityTracker(), onStateChange: { _ in })
            releasedMonitor = temporary
            temporary?.start(sources: [source])
            try Data("lifetime".utf8).write(to: file)
            temporary = nil
        }
        pause(0.5)
        require(releasedMonitor == nil, "queued callbacks must not retain discarded monitor")
        UserDefaults(suiteName: "io.github.laiyongqiang.SleepSkip.isolated.\(ProcessInfo.processInfo.processIdentifier)")?.removePersistentDomain(forName: "io.github.laiyongqiang.SleepSkip.isolated.\(ProcessInfo.processInfo.processIdentifier)")
        print("PASS: real FSEvents creation, ongoing writes, atomic replacement, metadata/removal filtering, absent-directory discovery, cap quiet expiry, monitor lifetime")
    }
}
