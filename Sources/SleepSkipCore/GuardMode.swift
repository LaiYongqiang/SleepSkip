import Foundation

public enum GuardMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Prevent idle system sleep while allowing the display to turn off.
    case background = "background"
    /// Prevent both idle system sleep and display sleep.
    case keepDisplay = "keepDisplay"

    public var id: String { rawValue }

    public var caffeinateAssertionFlags: [String] {
        switch self {
        case .background:
            return ["-i"]
        case .keepDisplay:
            return ["-di"]
        }
    }

    public var iconName: String {
        switch self {
        case .background:
            return "laptopcomputer"
        case .keepDisplay:
            return "sun.max"
        }
    }
}

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case zhHans = "zh-Hans"
    case en = "en"

    public var id: String { rawValue }

    public func resolvedIsChinese(preferredLanguages: [String] = Locale.preferredLanguages) -> Bool {
        switch self {
        case .zhHans:
            return true
        case .en:
            return false
        case .system:
            return preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false
        }
    }
}

/// How lid-closed sleep is suppressed.
///
/// Both strategies keep a closed lid awake. They differ in what they cost and in what they
/// can guarantee:
///
/// - `.unprivileged` sets `kPMSetClamshellSleepState` (IOPMrootDomain selector 12) and needs no
///   authorization. Measured limits: it holds for a full lid-closed session on a steady power
///   source, but **the machine sleeps 6–9 s after a power cable is plugged back in while the lid
///   is closed** — powerd's power-change path re-evaluates the lid and ignores the flag. Never
///   Sleep has the same limit; it was measured identically.
/// - `.privileged` uses `pmset -a disablesleep 1`, which powerd also honours on a power change.
///   It costs one admin authorization per start.
///
/// See `docs/CLAMSHELL-RESEARCH.md` for the measurements behind this.
public enum ClosedLidStrategy: String, CaseIterable, Sendable {
    /// No authorization. Fails to hold if the cable is reconnected with the lid shut.
    case unprivileged
    /// Admin authorization once per start. Holds across power changes.
    case privileged

    public var requiresAuthorization: Bool { self == .privileged }
}

public enum ThermalCutoff: String, CaseIterable, Identifiable, Sendable {
    case off = "off"
    case serious = "serious"
    case critical = "critical"

    public var id: String { rawValue }
}

public enum SessionTrigger: String, Codable, Sendable {
    case manual
    case autoFollow
    case url
}

public struct SessionHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let trigger: SessionTrigger
    public let mode: GuardMode
    public let closedLid: Bool
    public let agents: [String]
    public let startedAt: Date
    public let endedAt: Date
    public let stopReasonCode: String

    public init(
        id: UUID = UUID(),
        trigger: SessionTrigger,
        mode: GuardMode,
        closedLid: Bool,
        agents: [String] = [],
        startedAt: Date,
        endedAt: Date,
        stopReasonCode: String
    ) {
        self.id = id
        self.trigger = trigger
        self.mode = mode
        self.closedLid = closedLid
        self.agents = agents
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.stopReasonCode = stopReasonCode
    }
}

public struct SessionConfig: Equatable, Sendable {
    public var mode: GuardMode
    public var durationMinutes: Double
    public var customMinutes: Double
    public var lockOnStart: Bool
    public var allowClosedLid: Bool
    public var closedLidStrategy: ClosedLidStrategy
    public var batteryThresholdPercent: Int
    public var stopOnUnplug: Bool
    public var thermalCutoff: ThermalCutoff
    public var autoFollowAgents: Bool
    public var disabledAgentSourceIDs: [String]
    public var customAgentPaths: [String]
    public var globalShortcutEnabled: Bool
    public var language: AppLanguage

    public init(
        mode: GuardMode = .background,
        durationMinutes: Double = 240,
        customMinutes: Double = 90,
        lockOnStart: Bool = true,
        allowClosedLid: Bool = false,
        closedLidStrategy: ClosedLidStrategy = .unprivileged,
        batteryThresholdPercent: Int = 10,
        stopOnUnplug: Bool = false,
        thermalCutoff: ThermalCutoff = .critical,
        autoFollowAgents: Bool = true,
        disabledAgentSourceIDs: [String] = [],
        customAgentPaths: [String] = [],
        globalShortcutEnabled: Bool = true,
        language: AppLanguage = .system
    ) {
        self.mode = mode
        self.durationMinutes = durationMinutes
        self.customMinutes = customMinutes
        self.lockOnStart = lockOnStart
        self.allowClosedLid = allowClosedLid
        self.closedLidStrategy = closedLidStrategy
        self.batteryThresholdPercent = batteryThresholdPercent
        self.stopOnUnplug = stopOnUnplug
        self.thermalCutoff = thermalCutoff
        self.autoFollowAgents = autoFollowAgents
        self.disabledAgentSourceIDs = disabledAgentSourceIDs
        self.customAgentPaths = customAgentPaths
        self.globalShortcutEnabled = globalShortcutEnabled
        self.language = language
    }

    public static let standardPresets: [Double] = [30, 60, 120, 240, 0]

    public var effectiveAllowClosedLid: Bool {
        mode == .background && allowClosedLid
    }

    public var effectiveLockOnStart: Bool {
        mode == .background && lockOnStart
    }
}

public struct PowerSnapshot: Equatable, Sendable {
    public let onBattery: Bool
    public let percentage: Int?

    public init(onBattery: Bool, percentage: Int?) {
        self.onBattery = onBattery
        self.percentage = percentage
    }
}

public enum PowerEvent: Equatable, Sendable {
    case lowBattery(Int)
    case unplugged
}

public struct ExternalCLISession: Codable, Equatable, Sendable {
    public let pid: Int32
    public let commandName: String
    public let mode: GuardMode

    public init(pid: Int32, commandName: String, mode: GuardMode) {
        self.pid = pid
        self.commandName = commandName
        self.mode = mode
    }
}

public struct AssertionOwner: Equatable, Identifiable, Sendable {
    public let pid: Int32
    public let processName: String
    public let assertionType: String
    public let reason: String

    public var id: String { "\(pid)-\(assertionType)-\(reason)" }

    public init(pid: Int32, processName: String, assertionType: String, reason: String) {
        self.pid = pid
        self.processName = processName
        self.assertionType = assertionType
        self.reason = reason
    }
}

/// Snapshot persisted only when the GUI app's session state changes, allowing `sleepskip status`
/// to report live status with zero IPC server or background polling overhead.
public struct RuntimeStateSnapshot: Codable, Equatable, Sendable {
    public let appPID: Int32
    public let isRunning: Bool
    public let isFollowingAgents: Bool
    public let followingAgents: [String]
    public let mode: GuardMode
    public let closedLid: Bool
    public let isIndefinite: Bool
    public let endDate: Date?
    public let externalCLI: ExternalCLISession?
    public let updatedAt: Date

    public init(
        appPID: Int32,
        isRunning: Bool,
        isFollowingAgents: Bool,
        followingAgents: [String],
        mode: GuardMode,
        closedLid: Bool,
        isIndefinite: Bool,
        endDate: Date?,
        externalCLI: ExternalCLISession?,
        updatedAt: Date
    ) {
        self.appPID = appPID
        self.isRunning = isRunning
        self.isFollowingAgents = isFollowingAgents
        self.followingAgents = followingAgents
        self.mode = mode
        self.closedLid = closedLid
        self.isIndefinite = isIndefinite
        self.endDate = endDate
        self.externalCLI = externalCLI
        self.updatedAt = updatedAt
    }

    public static var defaultURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("SleepSkip", isDirectory: true)
            .appendingPathComponent("runtime-state.json")
    }

    public static func read(from url: URL = defaultURL) -> RuntimeStateSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RuntimeStateSnapshot.self, from: data)
    }

    public static func write(_ snapshot: RuntimeStateSnapshot, to url: URL = defaultURL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func remove(at url: URL = defaultURL) {
        try? FileManager.default.removeItem(at: url)
    }
}

public enum URLCommand: Equatable, Sendable {
    case start(mode: GuardMode?, minutes: Double?, lockOnStart: Bool?, allowClosedLid: Bool?)
    case stop
    case toggle
    case lock
    case open
}

public enum URLCommandParser {
    public static func parse(_ url: URL) -> URLCommand? {
        guard url.scheme?.lowercased() == "sleepskip" else { return nil }
        let host = (url.host ?? "").lowercased()
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let action = !host.isEmpty ? host : path

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        func boolValue(_ key: String) -> Bool? {
            guard let raw = queryItems.first(where: { $0.name.lowercased() == key })?.value?.lowercased() else {
                return nil
            }
            if ["1", "true", "yes", "on"].contains(raw) { return true }
            if ["0", "false", "no", "off"].contains(raw) { return false }
            return nil
        }

        switch action {
        case "start":
            let modeRaw = queryItems.first(where: { $0.name.lowercased() == "mode" })?.value?.lowercased()
            let mode: GuardMode? = {
                switch modeRaw {
                case "background", "bg": return .background
                case "keepdisplay", "display", "screen": return .keepDisplay
                default: return nil
                }
            }()
            let minutes: Double? = queryItems
                .first(where: { $0.name.lowercased() == "minutes" || $0.name.lowercased() == "duration" })
                .flatMap { $0.value }
                .flatMap { Double($0) }
                .flatMap { CommandBuilder.sanitizeMinutes($0) }
            let lock = boolValue("lock")
            let lid = boolValue("lid")
            return .start(mode: mode, minutes: minutes, lockOnStart: lock, allowClosedLid: lid)
        case "stop":
            return .stop
        case "toggle":
            return .toggle
        case "lock":
            return .lock
        case "open", "":
            return .open
        default:
            return nil
        }
    }
}

public enum HookAction: String, Equatable, Sendable {
    case start
    case stop
    case install
    case uninstall
}

public enum CLICommand: Equatable, Sendable {
    case help
    case version
    case gui(openPopover: Bool)
    case status(json: Bool)
    case doctor
    case control(action: String)
    case hook(action: HookAction, sessionID: String?, agent: String, pid: Int32?)
    case watchPID(pid: Int32, mode: GuardMode, lockOnFinish: Bool)
    case runCommand(arguments: [String], mode: GuardMode, lockOnFinish: Bool)
    /// Arguments that match nothing. Reported as an error rather than launching the GUI, so a
    /// typo like `sleepskip start` fails visibly instead of silently opening a menu bar app.
    case invalid(String)
}

public enum CLIParser {
    public static func parse(arguments: [String]) -> CLICommand {
        let args = Array(arguments.dropFirst())

        // Only options before `--` belong to SleepSkip. Everything after it is the wrapped
        // command's own argv and must be passed through untouched, even if it contains
        // `--version` or `--help`.
        let optionArgs: ArraySlice<String>
        let passthroughArgs: [String]
        if let dashIndex = args.firstIndex(of: "--") {
            optionArgs = args[..<dashIndex]
            passthroughArgs = Array(args[(dashIndex + 1)...])
        } else {
            optionArgs = args[...]
            passthroughArgs = []
        }

        if optionArgs.contains("--version") || optionArgs.contains("-v") {
            return .version
        }
        if optionArgs.contains("--help") || optionArgs.contains("-h") {
            return .help
        }

        var mode: GuardMode = .background
        var lockOnFinish = false

        if !passthroughArgs.isEmpty {
            for opt in optionArgs {
                if opt == "--display" || opt == "-d" {
                    mode = .keepDisplay
                } else if opt == "--lock" || opt == "-l" {
                    lockOnFinish = true
                }
            }
            return .runCommand(arguments: passthroughArgs, mode: mode, lockOnFinish: lockOnFinish)
        }

        if args.firstIndex(of: "--") != nil {
            // `--` was given with nothing after it: nothing to run.
            return .help
        }

        if let watchIdx = args.firstIndex(of: "watch") {
            var targetPID: Int32?
            for (idx, token) in args.enumerated() where idx != watchIdx {
                if token == "--display" || token == "-d" {
                    mode = .keepDisplay
                } else if token == "--lock" || token == "-l" {
                    lockOnFinish = true
                } else if targetPID == nil, let pid = Int32(token), pid > 0 {
                    targetPID = pid
                }
            }
            if let targetPID {
                return .watchPID(pid: targetPID, mode: mode, lockOnFinish: lockOnFinish)
            }
            return .invalid("watch needs a numeric pid")
        }

        if let first = args.first {
            if first == "status" {
                let extra = args.dropFirst()
                let unknown = extra.first { $0 != "--json" }
                if let unknown {
                    return .invalid("unknown option '\(unknown)' for status")
                }
                return .status(json: extra.contains("--json"))
            }
            if first == "doctor" {
                if args.count > 1 {
                    return .invalid("unknown option '\(args[1])' for doctor")
                }
                return .doctor
            }
            if ["stop", "toggle", "lock"].contains(first), args.count == 1 {
                return .control(action: first)
            }
            if first == "hook" {
                guard args.count >= 2, let action = HookAction(rawValue: args[1].lowercased()) else {
                    return .invalid("hook requires 'start', 'stop', 'install', or 'uninstall'")
                }
                if action == .install || action == .uninstall {
                    if args.count > 2 {
                        return .invalid("unknown option '\(args[2])' for hook \(action.rawValue)")
                    }
                    return .hook(action: action, sessionID: nil, agent: "claude-code", pid: nil)
                }
                var agent = "claude-code"
                var sessionID: String? = nil
                var pid: Int32? = nil
                var index = 2
                while index < args.count {
                    let token = args[index]
                    switch token {
                    case "--agent", "-a":
                        guard index + 1 < args.count, !args[index + 1].isEmpty else {
                            return .invalid("\(token) requires an agent name")
                        }
                        agent = args[index + 1]
                        index += 2
                    case "--session", "-s":
                        guard index + 1 < args.count, !args[index + 1].isEmpty else {
                            return .invalid("\(token) requires a session id")
                        }
                        sessionID = args[index + 1]
                        index += 2
                    case "--pid", "-p":
                        guard index + 1 < args.count, let parsedPID = Int32(args[index + 1]), parsedPID > 0 else {
                            return .invalid("\(token) requires a numeric pid")
                        }
                        pid = parsedPID
                        index += 2
                    default:
                        return .invalid("unknown option '\(token)' for hook")
                    }
                }
                return .hook(action: action, sessionID: sessionID, agent: agent, pid: pid)
            }
        }

        // Anything left over is not a recognised invocation. Launching the GUI here used to make
        // a mistyped subcommand look like a no-op, which is confusing in a terminal.
        let unrecognised = args.filter { !$0.hasPrefix("-") }
        if let first = unrecognised.first {
            return .invalid("unknown argument '\(first)'")
        }
        return .gui(openPopover: args.contains("--open"))
    }
}

public enum AppInfo {
    /// Packaging supplies the full release label without rewriting the source tree.
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "SleepSkipReleaseVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.6.0"
    }

    public static let repositoryURL = "https://github.com/LaiYongqiang/SleepSkip"

    public static let claudeCodeHookSnippet = """
    {
      "hooks": {
        "UserPromptSubmit": [{
          "hooks": [{ "type": "command", "command": "sleepskip hook start --agent claude-code >/dev/null 2>&1 || true" }]
        }],
        "Stop": [{
          "hooks": [{ "type": "command", "command": "sleepskip hook stop --agent claude-code >/dev/null 2>&1 || true" }]
        }]
      }
    }
    """
}

public enum CommandBuilder {
    /// Upper bound for a single session. Guards against `Double("inf")`, `1e300`, and typos
    /// that would otherwise crash `Int(_:)` when building the caffeinate timeout.
    public static let maxDurationMinutes: Double = 7 * 24 * 60

    public static func caffeinateArguments(
        mode: GuardMode,
        parentPID: Int32,
        timeoutSeconds: Int?
    ) -> [String] {
        var args = mode.caffeinateAssertionFlags
        args.append(contentsOf: ["-w", "\(parentPID)"])
        if let timeoutSeconds, timeoutSeconds > 0 {
            args.append(contentsOf: ["-t", "\(timeoutSeconds)"])
        }
        return args
    }

    /// Normalizes user-supplied minutes: nil when invalid or non-positive (indefinite).
    public static func sanitizeMinutes(_ minutes: Double) -> Double? {
        guard minutes.isFinite, minutes > 0 else { return nil }
        return min(minutes, maxDurationMinutes)
    }

    public static func timeoutSeconds(forMinutes minutes: Double) -> Int? {
        guard let safe = sanitizeMinutes(minutes) else { return nil }
        return max(1, Int((safe * 60.0).rounded()))
    }

    /// Shell command that disables lid-close sleep and restores it when the sentinel exits.
    ///
    /// Written to a file and run detached, not through `do shell script`:
    ///
    /// - `do shell script` waits for its output pipe to close, and a `&`-backgrounded child keeps
    ///   that pipe open, so the AppleScript call can hang until the sentinel dies.
    /// - Running detached means no process outlives the app, and the script's own PID can be
    ///   recorded so a leftover run can be cleaned up on the next launch.
    public static func closedLidWatchScript(watchPID: Int32) -> String {
        return """
        #!/bin/sh
        /usr/bin/pmset -a disablesleep 1 || exit 1
        trap '/usr/bin/pmset -a disablesleep 0' EXIT INT TERM
        /usr/bin/caffeinate -i -w \(watchPID) >/dev/null 2>&1
        /usr/bin/pmset -a disablesleep 0
        """
    }

    /// AppleScript that launches `closedLidWatchScript` as root and records its pid.
    ///
    /// The paths are single-quoted because `do shell script` runs the command through `/bin/sh`:
    /// `~/Library/Application Support/...` contains a space, so an unquoted path splits into
    /// `.../Library/Application` plus `Support/...`. The script then never runs, the command still
    /// exits 0, and the UI reports success while lid sleep was never disabled. `terminateDetachedGuard`
    /// also finds no pid file, so its cleanup silently does nothing.
    ///
    /// Single quotes (not double) so the value survives one more round of shell parsing, and the
    /// apostrophe is escaped the only way `sh` allows inside single quotes.
    public static func closedLidLaunchScript(scriptPath: String, pidPath: String) -> String {
        let quotedScript = shellSingleQuoted(scriptPath)
        let quotedPid = shellSingleQuoted(pidPath)
        return "nohup /bin/sh \(quotedScript) >/dev/null 2>&1 & echo $! > \(quotedPid)"
    }

    /// Wraps a path for `/bin/sh`, escaping embedded single quotes as `'\''`.
    public static func shellSingleQuoted(_ value: String) -> String {
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum DurationFormatter {
    public static func formatCountdown(_ totalSeconds: Int) -> String {
        let safe = max(0, totalSeconds)
        let h = safe / 3600
        let m = (safe % 3600) / 60
        let s = safe % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    public static func formatDuration(_ minutes: Double, isChinese: Bool) -> String {
        // Non-finite or out-of-range values fall back to "Indefinite" rather than trapping in Int(_:).
        guard let minutes = CommandBuilder.sanitizeMinutes(minutes) else {
            return isChinese ? "永久" : "Indefinite"
        }
        if minutes < 60 {
            let value = minutes == minutes.rounded() ? "\(Int(minutes))" : String(format: "%.1f", minutes)
            return isChinese ? "\(value) 分钟" : "\(value)m"
        }
        let hours = minutes / 60.0
        let value = hours == hours.rounded() ? "\(Int(hours))" : String(format: "%.1f", hours)
        if isChinese {
            return "\(value) 小时"
        }
        return hours == 1 ? "1 hour" : "\(value) hours"
    }

    public static func formatShortPreset(_ minutes: Double, isChinese: Bool) -> String {
        guard let minutes = CommandBuilder.sanitizeMinutes(minutes) else {
            return isChinese ? "永久" : "∞"
        }
        if minutes < 60 {
            return isChinese ? "\(Int(minutes)) 分" : "\(Int(minutes))m"
        }
        let hours = Int((minutes / 60.0).rounded())
        return isChinese ? "\(hours) 小时" : "\(hours)h"
    }

    public static func formatClockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

public enum PowerOutputParser {
    public static func parseSleepDisabled(fromPmsetOutput output: String) -> Bool {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("SleepDisabled") {
                let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
                if let last = parts.last, last == "1" {
                    return true
                }
            }
        }
        return false
    }

    /// Parses sleep-preventing assertions from `pmset -g assertions`.
    public static func parseAssertions(fromPmsetOutput output: String) -> [AssertionOwner] {
        let sleepTypes = [
            "PreventUserIdleSystemSleep",
            "PreventUserIdleDisplaySleep",
            "NoIdleSleepAssertion",
            "PreventSystemSleep",
        ]
        var results: [AssertionOwner] = []
        var seen = Set<String>()

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("pid "),
                  let matchedType = sleepTypes.first(where: { line.contains($0) }),
                  let openParen = line.firstIndex(of: "("),
                  let closeParen = line[openParen...].firstIndex(of: ")"),
                  let pid = Int32(line[line.index(line.startIndex, offsetBy: 4)..<openParen]) else {
                continue
            }

            let name = String(line[line.index(after: openParen)..<closeParen])
            let reason: String
            if let namedRange = line.range(of: "named: \"") {
                let afterQuote = line[namedRange.upperBound...]
                if let endQuote = afterQuote.firstIndex(of: "\"") {
                    reason = String(afterQuote[..<endQuote])
                } else {
                    reason = ""
                }
            } else {
                reason = ""
            }

            let entry = AssertionOwner(pid: pid, processName: name, assertionType: matchedType, reason: reason)
            if seen.insert(entry.id).inserted {
                results.append(entry)
            }
        }
        return results
    }
}
