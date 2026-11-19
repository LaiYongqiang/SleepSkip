import Foundation

/// One place worth watching for agent activity.
public struct AgentSource: Equatable, Sendable {
    /// Stable identifier used in state payloads, e.g. `"claude-code"`.
    public let id: String
    /// Name shown in the UI, e.g. `"Claude Code"`.
    public let displayName: String
    /// Directory that receives transcript writes while the agent works.
    public let path: String
    /// Filename suffixes that count as a transcript write. An empty array matches any non-hidden
    /// file inside `path` (used for user-selected custom directories).
    public let fileSuffixes: [String]
    public let isCustom: Bool

    public init(
        id: String,
        displayName: String,
        path: String,
        fileSuffixes: [String] = [".jsonl"],
        isCustom: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.path = Self.canonicalPath(path)
        self.fileSuffixes = fileSuffixes
        self.isCustom = isCustom
    }

    /// True when `path` looks like one of this source's transcript files.
    public func matches(filePath: String) -> Bool {
        let canonicalFilePath = Self.canonicalPath(filePath)
        guard canonicalFilePath.hasPrefix(path == "/" ? "/" : path + "/") else { return false }
        let relative = String(canonicalFilePath.dropFirst(path == "/" ? 1 : path.count + 1))
        let noisyDirectories: Set<String> = [".git", "node_modules", ".build", "DerivedData", ".Trash"]
        if relative.split(separator: "/").dropLast().contains(where: { noisyDirectories.contains(String($0)) }) {
            return false
        }
        let fileName = URL(fileURLWithPath: canonicalFilePath).lastPathComponent
        let noisySuffixes = [".tmp", ".swp", ".swo", "~", ".lock"]
        if fileName.isEmpty || fileName.hasPrefix(".") || noisySuffixes.contains(where: { fileName.hasSuffix($0) }) {
            return false
        }
        if fileSuffixes.isEmpty {
            return true
        }
        return fileSuffixes.contains { canonicalFilePath.hasSuffix($0) }
    }

    static func canonicalPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var ancestor = URL(fileURLWithPath: expanded).standardizedFileURL
        var missingComponents: [String] = []
        // FSEvents can report a file that has already disappeared, or one inside a directory
        // not created yet. Resolve the existing ancestor before appending that missing suffix.
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            missingComponents.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath()
        for component in missingComponents.reversed() { resolved.appendPathComponent(component) }
        return resolved.standardizedFileURL.path
    }

    /// Sources discovered on this machine. Missing directories are skipped by the monitor.
    public static func defaults(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [AgentSource] {
        [
            AgentSource(
                id: "claude-code",
                displayName: "Claude Code",
                path: homeDirectory.appendingPathComponent(".claude/projects").path
            ),
            AgentSource(
                id: "codex",
                displayName: "Codex",
                path: homeDirectory.appendingPathComponent(".codex/sessions").path
            ),
            AgentSource(
                id: "dsh",
                displayName: "DeepSeek Harness",
                path: homeDirectory.appendingPathComponent(".dsh/sessions").path,
                // DSH compresses its transcripts, so the extension is not `.jsonl`.
                fileSuffixes: [".jsonl.zstd", ".jsonl"]
            ),
            AgentSource(
                id: "gemini-cli",
                displayName: "Gemini CLI",
                path: homeDirectory.appendingPathComponent(".gemini/tmp").path,
                fileSuffixes: [".json"]
            ),
            AgentSource(
                id: "opencode",
                displayName: "OpenCode",
                path: homeDirectory.appendingPathComponent(".local/share/opencode").path,
                fileSuffixes: [".json", ".jsonl"]
            ),
        ]
    }

    /// Combines enabled built-in sources with user-defined custom directories.
    public static func configured(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        disabledSourceIDs: [String] = [],
        customPaths: [String] = []
    ) -> [AgentSource] {
        let disabled = Set(disabledSourceIDs)
        var result = defaults(homeDirectory: homeDirectory).filter { !disabled.contains($0.id) }
        var seenPaths = Set(result.map(\.path))
        for rawPath in customPaths {
            let expanded = (rawPath as NSString).expandingTildeInPath
            let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
            guard !standardized.isEmpty, seenPaths.insert(canonicalPath(standardized)).inserted else { continue }
            let name = URL(fileURLWithPath: standardized).lastPathComponent
            result.append(AgentSource(
                id: "custom:\(standardized)",
                displayName: name.isEmpty ? standardized : name,
                path: standardized,
                fileSuffixes: [],
                isCustom: true
            ))
        }
        return result
    }

    public static func displayName(forIdentifier identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Claude Code" }
        let normalized = trimmed.lowercased()
        switch normalized {
        case "claude-code", "claude code": return "Claude Code"
        case "codex": return "Codex"
        case "dsh", "deepseek harness": return "DeepSeek Harness"
        case "gemini-cli", "gemini cli": return "Gemini CLI"
        case "opencode": return "OpenCode"
        default: break
        }
        return trimmed
    }
}

public enum AgentActivityState: Equatable, Sendable {
    case inactive
    case active(agents: [String], lastActivity: Date)
    /// Quiet for longer than the activity window, but still inside the grace period.
    case grace(since: Date)

    public var isHolding: Bool {
        switch self {
        case .active, .grace: return true
        case .inactive: return false
        }
    }

    /// Two `active` states with different timestamps describe the same observable situation;
    /// comparing only the agent set keeps the UI from re-rendering on every transcript write.
    public var displayEquivalent: AgentActivityState {
        switch self {
        case .active(let agents, _): return .active(agents: agents, lastActivity: .distantPast)
        case .grace(let since): return .grace(since: since)
        case .inactive: return .inactive
        }
    }
}

public struct AgentActivityPolicy: Equatable, Sendable {
    /// How long a single write keeps an agent "active".
    public let activityWindow: TimeInterval
    /// Extra time to hold after the window lapses, covering tool calls that produce no output.
    public let gracePeriod: TimeInterval
    /// Hard ceiling for one automatic session, so a chatty background process cannot pin the Mac awake all night.
    public let maxAutoSessionDuration: TimeInterval

    public init(
        activityWindow: TimeInterval = 30,
        gracePeriod: TimeInterval = 300,
        maxAutoSessionDuration: TimeInterval = 2 * 3600
    ) {
        self.activityWindow = activityWindow
        self.gracePeriod = gracePeriod
        self.maxAutoSessionDuration = maxAutoSessionDuration
    }

    public static let `default` = AgentActivityPolicy()
}

/// Pure state machine deciding whether detected agent activity should hold a wake assertion.
/// Deliberately free of timers, file I/O and AppKit so it can be exercised in tests.
public final class AgentActivityTracker: @unchecked Sendable {
    private var policy: AgentActivityPolicy
    private let nowProvider: () -> Date
    private var subprocessActivityChecker: (Set<String>) -> Set<String>
    private let lock = NSLock()

    private var lastActivityBySource: [String: Date] = [:]
    private var subprocessExtendedSources: Set<String> = []
    private var sessionStart: Date?

    public init(
        policy: AgentActivityPolicy = .default,
        nowProvider: @escaping () -> Date = { Date() },
        subprocessActivityChecker: @escaping (Set<String>) -> Set<String> = { _ in [] }
    ) {
        self.policy = policy
        self.nowProvider = nowProvider
        self.subprocessActivityChecker = subprocessActivityChecker
    }

    public func setSubprocessActivityChecker(_ checker: @escaping (Set<String>) -> Set<String>) {
        lock.lock()
        subprocessActivityChecker = checker
        lock.unlock()
    }

    public var currentSubprocessExtendedSources: [String] {
        lock.lock()
        defer { lock.unlock() }
        return subprocessExtendedSources.sorted()
    }

    public var currentPolicy: AgentActivityPolicy {
        lock.lock()
        defer { lock.unlock() }
        return policy
    }

    public func setMaxAutoSessionDuration(_ duration: TimeInterval) {
        lock.lock()
        policy = AgentActivityPolicy(
            activityWindow: policy.activityWindow,
            gracePeriod: policy.gracePeriod,
            maxAutoSessionDuration: duration
        )
        lock.unlock()
    }

    public func recordActivity(sourceID: String) {
        let now = nowProvider()
        lock.lock()
        // A real quiet gap ends the old automatic window even if no timer evaluated it.
        if let last = lastActivityBySource.values.max(),
           now.timeIntervalSince(last) >= policy.activityWindow + policy.gracePeriod {
            lastActivityBySource.removeAll()
            subprocessExtendedSources.removeAll()
            sessionStart = nil
        }
        lastActivityBySource[sourceID] = now
        subprocessExtendedSources.remove(sourceID)
        if sessionStart == nil {
            sessionStart = now
        }
        lock.unlock()
    }

    public func evaluate() -> AgentActivityState {
        evaluate(at: nowProvider())
    }

    public func evaluate(at now: Date) -> AgentActivityState {
        lock.lock()
        let lastActivity = lastActivityBySource
        let currentPolicy = policy
        let checker = subprocessActivityChecker
        lock.unlock()

        let active = lastActivity
            .filter { now.timeIntervalSince($0.value) < currentPolicy.activityWindow }
            .keys
            .sorted()

        if !active.isEmpty {
            let newest = active.compactMap { lastActivity[$0] }.max() ?? now
            return .active(agents: active, lastActivity: newest)
        }

        guard let mostRecent = lastActivity.values.max() else { return .inactive }
        let quietSince = mostRecent.addingTimeInterval(currentPolicy.activityWindow)
        if now.timeIntervalSince(quietSince) < currentPolicy.gracePeriod {
            return .grace(since: quietSince)
        }

        // Transcript writes have been quiet past the grace window. Before releasing, check if
        // any tracked agent process still has an active tool/build subprocess running.
        let candidates = Set(lastActivity.keys)
        let busySubprocessSources = candidates.isEmpty ? [] : checker(candidates).intersection(candidates)
        if !busySubprocessSources.isEmpty {
            let syntheticLastActivity = now.addingTimeInterval(-currentPolicy.activityWindow)
            lock.lock()
            for sourceID in busySubprocessSources where lastActivityBySource[sourceID] != nil {
                lastActivityBySource[sourceID] = syntheticLastActivity
            }
            subprocessExtendedSources = busySubprocessSources
            lock.unlock()
            return .grace(since: now)
        }

        lock.lock()
        if let latest = lastActivityBySource.values.max(),
           now.timeIntervalSince(latest) >= currentPolicy.activityWindow + currentPolicy.gracePeriod {
            sessionStart = nil
            subprocessExtendedSources.removeAll()
        }
        lock.unlock()
        return .inactive
    }

    /// Releases only this source's transcript window; other sources retain activity and grace.
    public func removeActivity(sourceID: String) {
        let displayName = AgentSource.displayName(forIdentifier: sourceID)
        lock.lock()
        lastActivityBySource = lastActivityBySource.filter {
            AgentSource.displayName(forIdentifier: $0.key).lowercased() != displayName.lowercased()
        }
        subprocessExtendedSources = subprocessExtendedSources.filter {
            AgentSource.displayName(forIdentifier: $0).lowercased() != displayName.lowercased()
        }
        if lastActivityBySource.isEmpty {
            sessionStart = nil
            subprocessExtendedSources.removeAll()
        }
        lock.unlock()
    }

    public var holdingSourceIDs: [String] {
        let now = nowProvider()
        lock.lock()
        defer { lock.unlock() }
        return lastActivityBySource.filter {
            now.timeIntervalSince($0.value) < policy.activityWindow + policy.gracePeriod
        }.keys.sorted()
    }

    /// True once a single automatic session has run longer than the hard ceiling.
    public func autoSessionExceeded(at now: Date? = nil) -> Bool {
        let reference = now ?? nowProvider()
        lock.lock()
        let maxDuration = policy.maxAutoSessionDuration
        if let last = lastActivityBySource.values.max(),
           reference.timeIntervalSince(last) >= policy.activityWindow + policy.gracePeriod {
            sessionStart = nil
        }
        let start = sessionStart
        lock.unlock()
        guard maxDuration.isFinite, maxDuration > 0, let start else { return false }
        return reference.timeIntervalSince(start) >= maxDuration
    }

    /// Ends the current automatic session window but keeps recent activity, so a still-busy
    /// agent can be followed again immediately instead of waiting for a brand-new write.
    public func restartSessionWindow() {
        lock.lock()
        sessionStart = nowProvider()
        lock.unlock()
    }

    /// Drops all activity and ends the current automatic session.
    public func reset() {
        lock.lock()
        lastActivityBySource.removeAll()
        subprocessExtendedSources.removeAll()
        sessionStart = nil
        lock.unlock()
    }

    /// Whether the assertion should be held, given the state just computed.
    /// The ceiling wins over everything else so an unbounded session cannot pin the machine awake.
    public func shouldHoldAssertion(for state: AgentActivityState) -> Bool {
        guard state.isHolding else { return false }
        return !autoSessionExceeded()
    }
}

public protocol ClaudeHookControlling: AnyObject {
    var isConnected: Bool { get }
    func connect() throws
    func disconnect() throws
}

/// Manages SleepSkip `UserPromptSubmit` / `Stop` hooks inside `~/.claude/settings.json`
/// while preserving all unrelated settings and user hooks.
public final class ClaudeCodeHookManager: ClaudeHookControlling {
    private let settingsURL: URL
    private let fileManager: FileManager
    private let executableURL: URL?
    private static let ownershipMarker = " # SleepSkip managed hook v1"

    public init(
        settingsURL: URL = ClaudeCodeHookManager.defaultSettingsURL,
        fileManager: FileManager = .default,
        executableURL: URL? = Bundle.main.executableURL
    ) {
        self.settingsURL = settingsURL
        self.fileManager = fileManager
        self.executableURL = executableURL?.standardizedFileURL
    }

    public static var defaultSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    public var isConnected: Bool {
        guard (try? validateExecutable()) != nil,
              let root = try? readSettingsObject(createIfMissing: false),
              let hooks = root["hooks"] as? [String: Any] else {
            return false
        }
        return containsSleepSkipHook(in: hooks["UserPromptSubmit"], command: command(action: "start"))
            && containsSleepSkipHook(in: hooks["Stop"], command: command(action: "stop"))
    }

    public func connect() throws {
        try validateExecutable()
        let dir = settingsURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        var root = try readSettingsObject(createIfMissing: true)
        var hooks = try validatedHooks(in: root)
        hooks["UserPromptSubmit"] = ensuringHook(
            in: removingSleepSkipHooks(from: hooks["UserPromptSubmit"]),
            command: command(action: "start")
        )
        hooks["Stop"] = ensuringHook(
            in: removingSleepSkipHooks(from: hooks["Stop"]),
            command: command(action: "stop")
        )
        root["hooks"] = hooks
        try writeSettingsObject(root)
    }

    public func disconnect() throws {
        guard fileManager.fileExists(atPath: settingsURL.path) else { return }
        var root = try readSettingsObject(createIfMissing: false)
        guard root["hooks"] != nil else { return }
        var hooks = try validatedHooks(in: root)

        var changed = false
        for event in ["UserPromptSubmit", "Stop"] {
            let entries = (hooks[event] as? [[String: Any]]) ?? []
            guard entries.contains(where: { entry in
                let inner = (entry["hooks"] as? [[String: Any]]) ?? []
                return inner.contains { Self.isOwnedCommand(($0["command"] as? String) ?? "") }
            }) else { continue }
            changed = true
            let remaining = removingSleepSkipHooks(from: hooks[event])
            if remaining.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = remaining
            }
        }
        guard changed else { return }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        try writeSettingsObject(root)
    }

    private func command(action: String) -> String {
        let path = executableURL?.path ?? ""
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "\(quoted) hook \(action) --agent claude-code >/dev/null 2>&1 || true" + Self.ownershipMarker
    }

    private func validateExecutable() throws {
        guard let executableURL, executableURL.isFileURL,
              executableURL.path.hasPrefix("/"),
              fileManager.isExecutableFile(atPath: executableURL.path),
              (try? executableURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw hookError("SleepSkip executable is missing or is not executable")
        }
    }

    private func validatedHooks(in root: [String: Any]) throws -> [String: Any] {
        guard let raw = root["hooks"] else { return [:] }
        guard let hooks = raw as? [String: Any] else {
            throw hookError("The hooks setting must be a JSON object; settings were not changed")
        }
        for event in ["UserPromptSubmit", "Stop"] {
            if let rawEntries = hooks[event], !(rawEntries is [[String: Any]]) {
                throw hookError("The \(event) hooks must be an array; settings were not changed")
            }
        }
        return hooks
    }

    private func hookError(_ message: String) -> NSError {
        NSError(domain: "SleepSkip.ClaudeHook", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func isOwnedCommand(_ command: String) -> Bool {
        // Only strictly shaped generated commands with our ownership marker are ours.
        // A user's echo/example containing the words "sleepskip hook start" remains untouched.
        for action in ["start", "stop"] {
            let suffix = " hook \(action) --agent claude-code >/dev/null 2>&1 || true" + ownershipMarker
            guard command.hasSuffix(suffix) else { continue }
            let quotedPath = String(command.dropLast(suffix.count))
            guard quotedPath.hasPrefix("'/"), quotedPath.hasSuffix("'") else { continue }
            let path = String(quotedPath.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
            let requoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            if requoted == quotedPath { return true }
        }
        return false
    }

    private func readSettingsObject(createIfMissing: Bool) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: settingsURL.path) else {
            if createIfMissing { return [:] }
            return [:]
        }
        let data = try Data(contentsOf: settingsURL)
        if data.trimmingWhitespaceIsEmpty { return [:] }
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "SleepSkip.ClaudeHook",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid JSON object at \(settingsURL.path)"]
            )
        }
        return parsed
    }

    private func writeSettingsObject(_ root: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        var finalData = data
        finalData.append(0x0A)
        try finalData.write(to: settingsURL, options: .atomic)
    }

    private func containsSleepSkipHook(in rawEventList: Any?, command: String) -> Bool {
        guard let entries = rawEventList as? [[String: Any]] else { return false }
        for entry in entries {
            guard let innerHooks = entry["hooks"] as? [[String: Any]] else { continue }
            if innerHooks.contains(where: { ($0["command"] as? String) == command }) {
                return true
            }
        }
        return false
    }

    private func ensuringHook(in rawEventList: Any?, command: String) -> [[String: Any]] {
        var entries = (rawEventList as? [[String: Any]]) ?? []
        if containsSleepSkipHook(in: entries, command: command) {
            return entries
        }
        entries.append([
            "hooks": [
                ["type": "command", "command": command]
            ]
        ])
        return entries
    }

    private func removingSleepSkipHooks(from rawEventList: Any?) -> [[String: Any]] {
        guard let entries = rawEventList as? [[String: Any]] else { return [] }
        var kept: [[String: Any]] = []
        for var entry in entries {
            guard let innerHooks = entry["hooks"] as? [[String: Any]] else {
                kept.append(entry)
                continue
            }
            let filteredInner = innerHooks.filter {
                let cmd = ($0["command"] as? String) ?? ""
                return !Self.isOwnedCommand(cmd)
            }
            if filteredInner.count == innerHooks.count {
                kept.append(entry)
            } else if !filteredInner.isEmpty {
                entry["hooks"] = filteredInner
                kept.append(entry)
            }
        }
        return kept
    }
}

private extension Data {
    var trimmingWhitespaceIsEmpty: Bool {
        guard let text = String(data: self, encoding: .utf8) else { return isEmpty }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Detects whether any tracked Agent source process is currently executing a long-running
/// tool/build/test subprocess (or consuming active CPU) when its transcript goes quiet.
public enum AgentSubprocessDetector {
    public struct ProcessSnapshotRow: Equatable, Sendable {
        public let pid: Int32
        public let ppid: Int32
        public let cpuPercent: Double
        public let commandName: String

        public init(pid: Int32, ppid: Int32, cpuPercent: Double, commandName: String) {
            self.pid = pid
            self.ppid = ppid
            self.cpuPercent = cpuPercent
            self.commandName = commandName
        }
    }

    private static let toolExecutables: Set<String> = [
        "bash", "zsh", "sh", "fish",
        "swift", "swift-frontend", "swiftc", "xcodebuild", "xctest",
        "cargo", "rustc", "rustdoc",
        "clang", "clang++", "gcc", "g++", "cc", "c++", "ld",
        "make", "cmake", "ninja", "bazel", "buck2",
        "pytest", "python", "python3",
        "go", "javac", "java", "mvn", "gradle",
        "docker", "podman", "kubectl",
        "jest", "vitest", "playwright", "tsc", "webpack", "vite", "esbuild",
        "curl", "wget", "git", "ssh", "scp", "rsync",
        "tar", "zip", "unzip", "zstd", "gzip", "ffmpeg",
        "ruby", "php", "perl"
    ]

    public static func agentExecutableNames(for sourceID: String) -> Set<String> {
        switch sourceID.lowercased() {
        case "claude-code": return ["claude"]
        case "codex": return ["codex"]
        case "dsh": return ["dsh", "deepseek"]
        case "gemini-cli": return ["gemini"]
        case "opencode": return ["opencode"]
        default:
            if sourceID.hasPrefix("custom:") {
                let last = URL(fileURLWithPath: String(sourceID.dropFirst("custom:".count))).lastPathComponent.lowercased()
                let cleaned = last.hasPrefix(".") ? String(last.dropFirst()) : last
                return cleaned.isEmpty ? [] : [cleaned]
            }
            return [sourceID.lowercased()]
        }
    }

    public static func detectActiveSources(
        candidateSources: Set<String>,
        processes: [ProcessSnapshotRow]
    ) -> Set<String> {
        guard !candidateSources.isEmpty, !processes.isEmpty else { return [] }
        var childrenByParent: [Int32: [ProcessSnapshotRow]] = [:]
        var rowByPID: [Int32: ProcessSnapshotRow] = [:]
        for row in processes {
            rowByPID[row.pid] = row
            childrenByParent[row.ppid, default: []].append(row)
        }

        var busy: Set<String> = []
        for sourceID in candidateSources {
            let names = agentExecutableNames(for: sourceID)
            guard !names.isEmpty else { continue }
            let agentRoots = processes.filter { row in
                names.contains(normalizedExecutableName(row.commandName))
            }
            for root in agentRoots {
                if root.cpuPercent >= 2.0 || hasActiveDescendant(rootPID: root.pid, childrenByParent: childrenByParent) {
                    busy.insert(sourceID)
                    break
                }
            }
        }
        return busy
    }

    private static func hasActiveDescendant(
        rootPID: Int32,
        childrenByParent: [Int32: [ProcessSnapshotRow]]
    ) -> Bool {
        var visited: Set<Int32> = [rootPID]
        var queue: [Int32] = [rootPID]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            for child in childrenByParent[current] ?? [] where visited.insert(child.pid).inserted {
                let exec = normalizedExecutableName(child.commandName)
                if child.cpuPercent >= 1.0 || toolExecutables.contains(exec) {
                    return true
                }
                queue.append(child.pid)
            }
        }
        return false
    }

    private static func normalizedExecutableName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = URL(fileURLWithPath: trimmed).lastPathComponent.lowercased()
        return base.isEmpty ? trimmed.lowercased() : base
    }

    public static func parsePSOutput(_ output: String) -> [ProcessSnapshotRow] {
        var rows: [ProcessSnapshotRow] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 3, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 4,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]),
                  let cpu = Double(parts[2]) else { continue }
            rows.append(ProcessSnapshotRow(pid: pid, ppid: ppid, cpuPercent: cpu, commandName: String(parts[3])))
        }
        return rows
    }

    public static func liveActiveSources(among candidateSources: Set<String>) -> Set<String> {
        guard !candidateSources.isEmpty else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,pcpu=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8) else { return [] }
            return detectActiveSources(candidateSources: candidateSources, processes: parsePSOutput(output))
        } catch {
            return []
        }
    }
}
