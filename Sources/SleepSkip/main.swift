import Cocoa
import Foundation
import SleepSkipCore

private func postCLIDistributedNotification(_ name: Notification.Name, pid: Int32, commandName: String, mode: GuardMode) {
    DistributedNotificationCenter.default().postNotificationName(
        name,
        object: nil,
        userInfo: [
            "pid": NSNumber(value: pid),
            "cmd": commandName,
            "mode": mode.rawValue,
        ],
        deliverImmediately: true
    )
}

/// Keeps notifications and optional finish locking at the CLI boundary.
private func runWatched(arguments: [String], mode: GuardMode, commandLabel: String, lockOnFinish: Bool) -> Int32 {
    let pid = ProcessInfo.processInfo.processIdentifier
    postCLIDistributedNotification(IPCNotifications.cliStarted, pid: pid, commandName: commandLabel, mode: mode)
    defer {
        postCLIDistributedNotification(IPCNotifications.cliStopped, pid: pid, commandName: commandLabel, mode: mode)
        if lockOnFinish { ScreenLocker.lockScreenImmediate() }
    }
    return CLIProcessRunner.run(arguments: arguments, assertionFlags: mode.caffeinateAssertionFlags)
}

private func runWatchPID(targetPID: Int32, mode: GuardMode, lockOnFinish: Bool) -> Int32 {
    let pid = ProcessInfo.processInfo.processIdentifier
    let label = "PID \(targetPID)"
    postCLIDistributedNotification(IPCNotifications.cliStarted, pid: pid, commandName: label, mode: mode)
    defer {
        postCLIDistributedNotification(IPCNotifications.cliStopped, pid: pid, commandName: label, mode: mode)
        if lockOnFinish { ScreenLocker.lockScreenImmediate() }
    }
    return CLIProcessRunner.watch(pid: targetPID, assertionFlags: mode.caffeinateAssertionFlags)
}

private func printCLIStatus(json: Bool) -> Int32 {
    let snapshot = RuntimeStateSnapshot.read()
    let appAlive = snapshot.map { $0.appPID > 0 && kill($0.appPID, 0) == 0 } ?? false
    let activeSnapshot = appAlive ? snapshot : nil

    let isRunning = activeSnapshot?.isRunning ?? false
    let remainingSeconds: Int? = {
        guard let snap = activeSnapshot, snap.isRunning, !snap.isIndefinite, let end = snap.endDate else {
            return nil
        }
        return max(0, Int(end.timeIntervalSinceNow.rounded(.down)))
    }()

    if json {
        var payload: [String: Any] = [
            "appRunning": appAlive,
            "active": activeSnapshot.map { $0.isRunning || $0.externalCLI != nil } ?? false,
            "sessionRunning": isRunning,
            "followingAgents": activeSnapshot?.isFollowingAgents ?? false,
            "agents": activeSnapshot?.followingAgents ?? [],
            "mode": activeSnapshot?.mode.rawValue ?? "background",
            "closedLid": activeSnapshot?.closedLid ?? false,
            "indefinite": activeSnapshot?.isIndefinite ?? false,
        ]
        if let appPID = activeSnapshot?.appPID {
            payload["appPID"] = appPID
        }
        if let remainingSeconds {
            payload["remainingSeconds"] = remainingSeconds
        }
        if let cli = activeSnapshot?.externalCLI {
            payload["externalCLI"] = [
                "pid": cli.pid,
                "command": cli.commandName,
                "mode": cli.mode.rawValue,
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        return 0
    }

    guard let snap = activeSnapshot else {
        print("SleepSkip: app not running")
        return 0
    }
    if snap.isRunning {
        var parts = ["active", "mode=\(snap.mode.rawValue)"]
        if snap.isFollowingAgents, !snap.followingAgents.isEmpty {
            parts.append("agents=\(snap.followingAgents.joined(separator: ","))")
        }
        if snap.closedLid {
            parts.append("closedLid=true")
        }
        if let remainingSeconds {
            parts.append("remaining=\(DurationFormatter.formatCountdown(remainingSeconds))")
        } else if snap.isIndefinite {
            parts.append("indefinite=true")
        }
        print("SleepSkip: \(parts.joined(separator: " "))")
    } else if let cli = snap.externalCLI {
        print("SleepSkip: cli-guard cmd=\(cli.commandName) pid=\(cli.pid) mode=\(cli.mode.rawValue)")
    } else {
        print("SleepSkip: idle")
    }
    return 0
}

private func isMenuBarAppRunning() -> Bool {
    let selfPID = ProcessInfo.processInfo.processIdentifier
    if let snap = RuntimeStateSnapshot.read(),
       snap.appPID > 0,
       snap.appPID != selfPID,
       kill(snap.appPID, 0) == 0 {
        return true
    }
    return NSRunningApplication
        .runningApplications(withBundleIdentifier: "io.github.laiyongqiang.SleepSkip")
        .contains { $0.processIdentifier != selfPID }
}

private func sendCLIControl(_ action: String) -> Int32 {
    guard isMenuBarAppRunning() else {
        if action == "lock" {
            ScreenLocker.lockScreenImmediate()
            return 0
        }
        fputs("SleepSkip CLI error: SleepSkip menu bar app is not running.\n", stderr)
        return 1
    }
    DistributedNotificationCenter.default().postNotificationName(
        IPCNotifications.controlCommand,
        object: nil,
        userInfo: ["action": action],
        deliverImmediately: true
    )
    return 0
}

private func sendHookEvent(action: HookAction, sessionID: String?, agent: String, pid: Int32?) -> Int32 {
    guard isMenuBarAppRunning() else {
        fputs("SleepSkip CLI error: SleepSkip menu bar app is not running.\n", stderr)
        return 1
    }
    let resolvedSessionID: String
    do {
        guard let identity = try sessionID ?? CLIHookInput.readSessionID() else {
            fputs("SleepSkip CLI error: provide --session <id> or JSON stdin containing session_id.\n", stderr)
            return 2
        }
        let normalizedIdentity = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedIdentity.isEmpty else {
            fputs("SleepSkip CLI error: --session requires a nonempty session id.\n", stderr)
            return 2
        }
        resolvedSessionID = normalizedIdentity
    } catch {
        fputs("SleepSkip CLI error: \(error.localizedDescription)\n", stderr)
        return 2
    }
    var info: [AnyHashable: Any] = [
        "action": action.rawValue,
        "agent": agent,
        "sessionID": resolvedSessionID,
    ]
    if let pid, pid > 0 {
        info["pid"] = NSNumber(value: pid)
    }
    DistributedNotificationCenter.default().postNotificationName(
        IPCNotifications.hookEvent,
        object: nil,
        userInfo: info,
        deliverImmediately: true
    )
    return 0
}

private func runDoctor() -> Int32 {
    let appUp = isMenuBarAppRunning()
    let snap = appUp ? RuntimeStateSnapshot.read() : nil
    let cliInstalled: Bool = {
        let candidates = ["/opt/homebrew/bin/sleepskip", "/usr/local/bin/sleepskip"]
        return candidates.contains { FileManager.default.fileExists(atPath: $0) }
    }()
    let hookConnected = ClaudeCodeHookManager().isConnected

    var sleepDisabled = false
    var assertions: [AssertionOwner] = []

    let pmsetTask = Process()
    pmsetTask.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    pmsetTask.arguments = ["-g"]
    let pmsetPipe = Pipe()
    pmsetTask.standardOutput = pmsetPipe
    pmsetTask.standardError = FileHandle.nullDevice
    if (try? pmsetTask.run()) != nil {
        pmsetTask.waitUntilExit()
        let output = String(data: pmsetPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        sleepDisabled = PowerOutputParser.parseSleepDisabled(fromPmsetOutput: output)
    }

    let assertionsTask = Process()
    assertionsTask.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    assertionsTask.arguments = ["-g", "assertions"]
    let assertionsPipe = Pipe()
    assertionsTask.standardOutput = assertionsPipe
    assertionsTask.standardError = FileHandle.nullDevice
    if (try? assertionsTask.run()) != nil {
        assertionsTask.waitUntilExit()
        let output = String(data: assertionsPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        assertions = PowerOutputParser.parseAssertions(fromPmsetOutput: output)
    }

    print("SleepSkip \(AppInfo.version) Doctor")
    print("  Menu bar app:      \(appUp ? (snap?.isRunning == true ? "running (active: \(snap?.mode.rawValue ?? "background"))" : "running (idle)") : "not running")")
    print("  CLI symlink:       \(cliInstalled ? "installed" : "not installed")")
    print("  Claude Code hook:  \(hookConnected ? "connected (~/.claude/settings.json)" : "not connected")")
    print("  System SleepDisabled: \(sleepDisabled ? "1 (disabled)" : "0 (normal)")")
    if assertions.isEmpty {
        print("  Sleep assertions:  none")
    } else {
        print("  Sleep assertions (\(assertions.count)):")
        for owner in assertions.prefix(10) {
            let reasonSuffix = owner.reason.isEmpty ? "" : " \"\(owner.reason)\""
            print("    - \(owner.processName) (pid \(owner.pid)) · \(owner.assertionType)\(reasonSuffix)")
        }
    }
    return 0
}

switch CLIParser.parse(arguments: CommandLine.arguments) {
case .version:
    print("SleepSkip \(AppInfo.version)")
    exit(0)

case .help:
    print("""
    SleepSkip — Ultra-lightweight macOS keep-awake menu bar & CLI utility
    Usage:
      SleepSkip                         Launch menu bar app
      SleepSkip --open                  Launch and open popover immediately
      SleepSkip status [--json]         Inspect current keep-awake status
      SleepSkip doctor                  Inspect power assertions, hooks, and app health
      SleepSkip stop | toggle | lock    Control running menu bar session
      SleepSkip hook install|uninstall  Manage ~/.claude/settings.json Claude Code hooks
      SleepSkip hook start|stop [--agent <name>] [--session <id>] [--pid <pid>]
                                         Explicit agent hook lease (instant start/stop)
      SleepSkip [--display] [--lock] -- <command...>
                                         Keep Mac awake until <command> finishes
      SleepSkip watch [--display] [--lock] <pid>
                                         Keep Mac awake until existing <pid> exits
      SleepSkip --version               Show version
    """)
    exit(0)

case .status(let json):
    exit(printCLIStatus(json: json))

case .doctor:
    exit(runDoctor())

case .control(let action):
    exit(sendCLIControl(action))

case .hook(let action, let sessionID, let agent, let pid):
    switch action {
    case .install:
        do {
            try ClaudeCodeHookManager().connect()
            print("Connected SleepSkip hooks in ~/.claude/settings.json")
            exit(0)
        } catch {
            fputs("SleepSkip CLI error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    case .uninstall:
        do {
            try ClaudeCodeHookManager().disconnect()
            print("Removed SleepSkip hooks from ~/.claude/settings.json")
            exit(0)
        } catch {
            fputs("SleepSkip CLI error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    case .start, .stop:
        exit(sendHookEvent(action: action, sessionID: sessionID, agent: agent, pid: pid))
    }

case .runCommand(let cmdArgs, let mode, let lockOnFinish):
    guard let executable = cmdArgs.first, !executable.isEmpty else {
        fputs("SleepSkip CLI error: no command given after --\n", stderr)
        exit(2)
    }
    let cmdLabel = URL(fileURLWithPath: executable).lastPathComponent
    let status = runWatched(
        arguments: cmdArgs,
        mode: mode,
        commandLabel: cmdLabel,
        lockOnFinish: lockOnFinish
    )
    exit(status)

case .watchPID(let targetPID, let mode, let lockOnFinish):
    exit(runWatchPID(targetPID: targetPID, mode: mode, lockOnFinish: lockOnFinish))

case .invalid(let reason):
    fputs("SleepSkip CLI error: \(reason)\nRun `SleepSkip --help` for usage.\n", stderr)
    exit(2)

case .gui:
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
