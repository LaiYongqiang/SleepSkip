import Cocoa
import Darwin
import Foundation
import IOKit.ps
import ServiceManagement
import SleepSkipCore
import UserNotifications

final class CaffeinateRunner: CaffeinateRunning {
    private var process: Process?

    var isActive: Bool {
        process?.isRunning ?? false
    }

    func start(mode: GuardMode, timeoutSeconds: Int?, onUnexpectedExit: @escaping () -> Void) throws {
        let newProc = Process()
        newProc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        newProc.arguments = CommandBuilder.caffeinateArguments(
            mode: mode,
            parentPID: ProcessInfo.processInfo.processIdentifier,
            timeoutSeconds: timeoutSeconds
        )
        newProc.standardInput = FileHandle.nullDevice
        newProc.standardOutput = FileHandle.nullDevice
        newProc.standardError = FileHandle.nullDevice

        newProc.terminationHandler = { [weak self, weak newProc] _ in
            DispatchQueue.main.async {
                guard let self, let newProc, self.process === newProc else { return }
                self.process = nil
                onUnexpectedExit()
            }
        }

        try newProc.run()
        let old = process
        process = newProc
        old?.terminate()
    }

    func stop() {
        let old = process
        process = nil
        old?.terminate()
    }
}

final class BackpackGuard: BackpackGuarding {
    private final class Attempt {
        let token = UUID()
        let process: Process
        let pipe: Pipe
        let scriptURL: URL
        var pidURL: URL { scriptURL.appendingPathExtension("pid") }
        var readyURL: URL { scriptURL.appendingPathExtension("ready") }
        init(process: Process, pipe: Pipe, scriptURL: URL) {
            self.process = process; self.pipe = pipe; self.scriptURL = scriptURL
        }
        func cancel() {
            try? pipe.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            // Removing the script also prevents an authorization dialog accepted after cancel
            // from starting this attempt. Each attempt has its own script and pid file.
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: readyURL)
            if let raw = try? String(contentsOf: pidURL, encoding: .utf8),
               let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
               ProcessArguments.mentions(pid: pid, scriptName: scriptURL.lastPathComponent) {
                kill(pid, SIGTERM)
            }
            try? FileManager.default.removeItem(at: pidURL)
        }
    }
    typealias Authorizer = (String, @escaping (Result<Void, Error>) -> Void) -> Void
    private var attempt: Attempt?
    private let authorize: Authorizer
    private let storageDirectory: URL
    private let sleepChecker: ((@escaping (Bool) -> Void) -> Void)?
    private let readinessChecker: (URL) -> Bool

    init(storageDirectory: URL? = nil, authorization: Authorizer? = nil,
         sleepChecker: ((@escaping (Bool) -> Void) -> Void)? = nil,
         readinessChecker: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) {
        self.storageDirectory = storageDirectory ?? URL(fileURLWithPath: Self.scriptPath).deletingLastPathComponent()
        self.sleepChecker = sleepChecker
        self.readinessChecker = readinessChecker
        self.authorize = authorization ?? { command, completion in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let source = "do shell script \"\(command)\" with administrator privileges"
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                let outcome: Result<Void, Error>
                if result != nil { outcome = .success(()) }
                else {
                    outcome = .failure(NSError(domain: "SleepSkip.BackpackGuard",
                        code: (error?[NSAppleScript.errorNumber] as? Int) ?? -1,
                        userInfo: [NSLocalizedDescriptionKey: (error?[NSAppleScript.errorMessage] as? String) ?? "Authorization failed"]))
                }
                DispatchQueue.main.async { completion(outcome) }
            }
        }
    }

    deinit { attempt?.cancel() }

    /// Legacy location is retained only for one-time cleanup of versions before attempt tokens.
    static var scriptPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SleepSkip", isDirectory: true) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("lid-guard.sh").path
    }
    static var pidPath: String { scriptPath + ".pid" }
    var isActive: Bool { attempt?.process.isRunning ?? false }

    func enable(completion: @escaping (Result<Void, Error>) -> Void) {
        disable()
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let current = Attempt(process: process, pipe: pipe,
            scriptURL: storageDirectory.appendingPathComponent("lid-guard-\(UUID().uuidString).sh"))
        do {
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            try process.run()
            let script = Self.watchScript(watchPID: process.processIdentifier, readyURL: current.readyURL)
            try script.write(to: current.scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current.scriptURL.path)
        } catch {
            current.cancel(); completion(.failure(error)); return
        }
        attempt = current
        let command = Self.serializedLaunchCommand(scriptURL: current.scriptURL, pidURL: current.pidURL,
            lockURL: storageDirectory.appendingPathComponent("lid-guard.lock"))
        authorize(command) { [weak self, current] result in
            guard let self, self.attempt === current else {
                current.cancel()
                completion(.failure(NSError(domain: "SleepSkip.BackpackGuard", code: NSUserCancelledError)))
                return
            }
            switch result {
            case .failure(let error):
                self.disable(); completion(.failure(error))
            case .success:
                self.verifySleepDisabled(attempt: current, retriesRemaining: 25) { [weak self, current] verified in
                    guard let self, self.attempt === current else {
                        current.cancel()
                        completion(.failure(NSError(domain: "SleepSkip.BackpackGuard", code: NSUserCancelledError)))
                        return
                    }
                    if verified { completion(.success(())) }
                    else {
                        self.disable()
                        completion(.failure(NSError(domain: "SleepSkip.BackpackGuard", code: -2,
                            userInfo: [NSLocalizedDescriptionKey: "Lid-close sleep was not disabled. The guard may have been blocked by a system policy."])))
                    }
                }
            }
        }
    }

    static func watchScript(watchPID: Int32, readyURL: URL,
                            powerCommand: String = "/usr/bin/pmset",
                            waitCommand: String = "/usr/bin/caffeinate") -> String {
        let power = CommandBuilder.shellSingleQuoted(powerCommand)
        let wait = CommandBuilder.shellSingleQuoted(waitCommand)
        let readyPath = CommandBuilder.shellSingleQuoted(readyURL.path)
        let cleanup = CommandBuilder.shellSingleQuoted("/bin/rm -f \(readyPath); \(power) -a disablesleep 0")
        return """
        #!/bin/sh
        /bin/kill -0 \(watchPID) 2>/dev/null || exit 0
        \(power) -a disablesleep 1 || exit 1
        trap \(cleanup) EXIT
        trap 'exit 0' INT TERM
        /usr/bin/touch \(readyPath)
        \(wait) -i -w \(watchPID) >/dev/null 2>&1
        """
    }

    /// Keep the lock inode and hold it through the script's EXIT restoration. A replacement
    /// guard cannot set the shared flag until its predecessor has restored and exited.
    static func serializedLaunchCommand(scriptURL: URL, pidURL: URL, lockURL: URL) -> String {
        let script = CommandBuilder.shellSingleQuoted(scriptURL.path)
        let pid = CommandBuilder.shellSingleQuoted(pidURL.path)
        let lock = CommandBuilder.shellSingleQuoted(lockURL.path)
        return "nohup /usr/bin/lockf -k -t 3 \(lock) /bin/sh \(script) >/dev/null 2>&1 & echo $! > \(pid)"
    }

    private func verifySleepDisabled(attempt current: Attempt, retriesRemaining: Int, completion: @escaping (Bool) -> Void) {
        guard attempt === current else { completion(false); return }
        checkSleepDisabledAsync { [weak self] disabled in
            guard let self, self.attempt === current else { completion(false); return }
            if disabled && self.readinessChecker(current.readyURL) { completion(true) }
            else if retriesRemaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self else { completion(false); return }
                    self.verifySleepDisabled(attempt: current, retriesRemaining: retriesRemaining - 1, completion: completion)
                }
            } else { completion(false) }
        }
    }

    func disable() {
        let old = attempt
        attempt = nil
        old?.cancel()
    }

    /// Stops a guard script left running by a previous session. Without this, a crash or force-quit
    /// leaves `disablesleep 1` in place with nothing watching the sentinel.
    static func terminateDetachedGuard() {
        guard let raw = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else {
            try? FileManager.default.removeItem(atPath: pidPath)
            return
        }
        // The pid file survives restarts, so verify it still belongs to our script before
        // signalling. `proc_pidpath` reports the *executable*, which for `sh script.sh` is
        // `/bin/bash` or `/bin/sh` — never the script — so match on the command line instead.
        if isOurGuardScript(pid: pid) {
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(atPath: pidPath)
    }

    /// True when `pid` is a live process whose arguments name our guard script.
    ///
    /// `proc_pidpath` reports the *executable*, which for `sh script.sh` is `/bin/bash` — never
    /// the script — so the old `hasSuffix("lid-guard.sh")` check was always false and the safety
    /// net never fired. The script path only appears in argv; see `ProcessArguments`.
    static func isOurGuardScript(pid: Int32) -> Bool {
        guard pid > 0 else { return false }

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        if proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 {
            // Fast path: the kernel ran the script directly via its shebang.
            if String(cString: pathBuffer).hasSuffix("lid-guard.sh") { return true }
        }

        return ProcessArguments.mentions(pid: pid, scriptName: "lid-guard.sh")
    }

    func checkSleepDisabledAsync(completion: @escaping (Bool) -> Void) {
        if let sleepChecker { sleepChecker(completion); return }
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            task.arguments = ["-g"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            var disabled = false
            if (try? task.run()) != nil {
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                disabled = PowerOutputParser.parseSleepDisabled(fromPmsetOutput: output)
            }
            DispatchQueue.main.async {
                completion(disabled)
            }
        }
    }

    func restoreNormalSleepAsync(completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var errorDict: NSDictionary?
            let script = NSAppleScript(source: "do shell script \"/usr/bin/pmset -a disablesleep 0\" with administrator privileges")
            let result = script?.executeAndReturnError(&errorDict)

            guard result != nil else {
                DispatchQueue.main.async {
                    let msg = (errorDict?[NSAppleScript.errorMessage] as? String) ?? "Failed to restore normal sleep"
                    completion(.failure(NSError(domain: "SleepSkip.BackpackGuard", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: msg
                    ])))
                }
                return
            }

            // Same reasoning as `enable`: an exit code of 0 only means the shell ran. Leaving
            // `disablesleep 1` behind is the worse failure of the two, so confirm it actually
            // cleared rather than reporting success on the shell's word alone.
            self.verifySleepEnabled(retriesRemaining: 10) { restored in
                DispatchQueue.main.async {
                    if restored {
                        completion(.success(()))
                    } else {
                        completion(.failure(NSError(domain: "SleepSkip.BackpackGuard", code: -3, userInfo: [
                            NSLocalizedDescriptionKey: "Normal sleep could not be restored. Run `sudo pmset -a disablesleep 0` manually."
                        ])))
                    }
                }
            }
        }
    }

    /// Polls `SleepDisabled` until it reads 0 or the retries run out.
    private func verifySleepEnabled(retriesRemaining: Int, completion: @escaping (Bool) -> Void) {
        checkSleepDisabledAsync { disabled in
            if !disabled {
                completion(true)
            } else if retriesRemaining > 0 {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) {
                    self.verifySleepEnabled(retriesRemaining: retriesRemaining - 1, completion: completion)
                }
            } else {
                completion(false)
            }
        }
    }
}

final class PowerMonitor: PowerMonitoring {
    private var runLoopSource: CFRunLoopSource?
    private var thresholdPercent: Int = 0
    private var stopOnUnplug: Bool = false
    private var wasOnBattery: Bool? = nil
    private var callback: ((PowerEvent) -> Void)?

    func currentPowerSnapshot() -> PowerSnapshot? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }

        for ps in list {
            guard let info = IOPSGetPowerSourceDescription(snapshot, ps)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            guard let powerState = info[kIOPSPowerSourceStateKey as String] as? String else {
                continue
            }
            let onBattery = (powerState == kIOPSBatteryPowerValue)
            let capacity = info[kIOPSCurrentCapacityKey as String] as? Int
            return PowerSnapshot(onBattery: onBattery, percentage: capacity)
        }
        return nil
    }

    func start(thresholdPercent: Int, stopOnUnplug: Bool, onEvent: @escaping (PowerEvent) -> Void) {
        stop()
        guard thresholdPercent > 0 || stopOnUnplug else { return }

        self.thresholdPercent = thresholdPercent
        self.stopOnUnplug = stopOnUnplug
        self.wasOnBattery = currentPowerSnapshot()?.onBattery
        self.callback = onEvent

        let unmanagedSelf = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.evaluatePowerState()
        }, unmanagedSelf)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }

        evaluatePowerState()
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = nil
        }
        callback = nil
        wasOnBattery = nil
    }

    private func evaluatePowerState() {
        guard thresholdPercent > 0 || stopOnUnplug, let callback else { return }
        guard let snapshot = currentPowerSnapshot() else { return }

        if stopOnUnplug, let prev = wasOnBattery, prev == false, snapshot.onBattery {
            self.stop()
            DispatchQueue.main.async {
                callback(.unplugged)
            }
            return
        }
        wasOnBattery = snapshot.onBattery

        if thresholdPercent > 0, snapshot.onBattery,
           let pct = snapshot.percentage, pct <= thresholdPercent {
            self.stop()
            DispatchQueue.main.async {
                callback(.lowBattery(pct))
            }
        }
    }

    deinit {
        stop()
    }

    /// Reads active system sleep assertions once on demand (never polled).
    static func fetchAssertions(completion: @escaping ([AssertionOwner]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            let pipe = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            proc.arguments = ["-g", "assertions"]
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice

            var parsed: [AssertionOwner] = []
            do {
                try proc.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                if let text = String(data: data, encoding: .utf8) {
                    parsed = PowerOutputParser.parseAssertions(fromPmsetOutput: text)
                }
            } catch {
                parsed = []
            }

            DispatchQueue.main.async {
                completion(parsed)
            }
        }
    }
}

final class ScreenLocker: ScreenLocking {
    static func lockScreenImmediate() {
        typealias LockFn = @convention(c) () -> Void
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let sym = dlsym(handle, "SACLockScreenImmediate") {
            let lockFn = unsafeBitCast(sym, to: LockFn.self)
            lockFn()
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"System Events\" to keystroke \"q\" using {control down, command down}"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }

    func lockScreen() {
        Self.lockScreenImmediate()
    }
}

final class NativeNotifier: UserNotifying {
    private var didRequestPermission = false

    private var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    func preparePermissionIfNeeded() {
        guard isAppBundle, !didRequestPermission else { return }
        didRequestPermission = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func send(title: String, body: String) {
        guard isAppBundle else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "io.github.laiyongqiang.SleepSkip.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

final class LoginItemManager: LoginItemControlling {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        }
    }
}

/// Event-driven thermal observer backed by `ProcessInfo.thermalStateDidChangeNotification`.
/// Consumes zero background CPU or wakeups when the system stays below the configured threshold.
final class ThermalMonitor: ThermalMonitoring {
    private var observer: NSObjectProtocol?
    private var cutoff: ThermalCutoff = .critical
    private var onOverheated: (() -> Void)?

    func isOverheated(cutoff: ThermalCutoff) -> Bool {
        Self.exceeds(ProcessInfo.processInfo.thermalState, cutoff: cutoff)
    }

    func start(cutoff: ThermalCutoff, onOverheated: @escaping () -> Void) {
        stop()
        guard cutoff != .off else { return }
        self.cutoff = cutoff
        self.onOverheated = onOverheated

        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.evaluate()
        }
        evaluate()
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        onOverheated = nil
    }

    private func evaluate() {
        guard let onOverheated, Self.exceeds(ProcessInfo.processInfo.thermalState, cutoff: cutoff) else {
            return
        }
        stop()
        DispatchQueue.main.async {
            onOverheated()
        }
    }

    static func exceeds(_ state: ProcessInfo.ThermalState, cutoff: ThermalCutoff) -> Bool {
        switch cutoff {
        case .off:
            return false
        case .serious:
            return state == .serious || state == .critical
        case .critical:
            return state == .critical
        }
    }

    deinit {
        stop()
    }
}

final class CLICommandInstaller: CLIInstalling {
    private var bundleExecutablePath: String? {
        guard Bundle.main.bundleURL.pathExtension == "app",
              let exec = Bundle.main.executablePath,
              FileManager.default.isExecutableFile(atPath: exec) else {
            return nil
        }
        return exec
    }

    func currentStatus() -> CLIInstallStatus {
        guard let exec = bundleExecutablePath else {
            return .unavailable
        }
        let targetResolved = URL(fileURLWithPath: exec).resolvingSymlinksInPath().path
        let candidates = [
            "/opt/homebrew/bin/sleepskip",
            "/usr/local/bin/sleepskip",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/sleepskip").path,
        ]
        for path in candidates {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if resolved == targetResolved {
                return .installed(path: path)
            }
        }
        return .notInstalled
    }

    func install(completion: @escaping (Result<String, Error>) -> Void) {
        guard let exec = bundleExecutablePath else {
            completion(.failure(NSError(
                domain: "SleepSkip.CLIInstaller",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "CLI installation is only available from SleepSkip.app."]
            )))
            return
        }

        let fm = FileManager.default
        let preferredDir = fm.isWritableFile(atPath: "/opt/homebrew/bin")
            ? "/opt/homebrew/bin"
            : "/usr/local/bin"
        let linkPath = (preferredDir as NSString).appendingPathComponent("sleepskip")

        // Use direct filesystem symlink when writable; fall back to standard admin prompt otherwise.
        if fm.isWritableFile(atPath: preferredDir) || (!fm.fileExists(atPath: preferredDir) && fm.isWritableFile(atPath: (preferredDir as NSString).deletingLastPathComponent)) {
            do {
                try fm.createDirectory(atPath: preferredDir, withIntermediateDirectories: true)
                if fm.fileExists(atPath: linkPath) {
                    try fm.removeItem(atPath: linkPath)
                }
                try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: exec)
                completion(.success(linkPath))
                return
            } catch {
                // Fall through to privileged symlink creation if direct write fails.
            }
        }

        let quotedExec = CommandBuilder.shellSingleQuoted(exec)
        let quotedLink = CommandBuilder.shellSingleQuoted("/usr/local/bin/sleepskip")
        let shellCmd = "mkdir -p /usr/local/bin && ln -sf \(quotedExec) \(quotedLink)"

        DispatchQueue.global(qos: .userInitiated).async {
            var errorDict: NSDictionary?
            let script = NSAppleScript(source: "do shell script \"\(shellCmd)\" with administrator privileges")
            let result = script?.executeAndReturnError(&errorDict)
            DispatchQueue.main.async {
                if result != nil {
                    completion(.success("/usr/local/bin/sleepskip"))
                } else {
                    let msg = (errorDict?[NSAppleScript.errorMessage] as? String) ?? "Failed to install CLI symlink"
                    completion(.failure(NSError(
                        domain: "SleepSkip.CLIInstaller",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: msg]
                    )))
                }
            }
        }
    }
}

/// An isolated window exercises the interface without acquiring shared system resources.
/// Every dependency is inert, including settings actions such as lock, hooks and CLI install.
final class IsolatedSystemServices: CaffeinateRunning, BackpackGuarding, ClosedLidGuarding,
    PowerMonitoring, ThermalMonitoring, ScreenLocking, UserNotifying, LoginItemControlling,
    CLIInstalling, ClaudeHookControlling {
    private(set) var isActive = false
    private(set) var isEngaged = false
    var isEnabled = false
    var isConnected = false
    func start(mode: GuardMode, timeoutSeconds: Int?, onUnexpectedExit: @escaping () -> Void) throws { isActive = true }
    func stop() { isActive = false }
    func enable(completion: @escaping (Result<Void, Error>) -> Void) { isEngaged = true; completion(.success(())) }
    func disable() { isEngaged = false }
    func checkSleepDisabledAsync(completion: @escaping (Bool) -> Void) { completion(false) }
    func restoreNormalSleepAsync(completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
    func currentPowerSnapshot() -> PowerSnapshot? { nil }
    func start(thresholdPercent: Int, stopOnUnplug: Bool, onEvent: @escaping (PowerEvent) -> Void) {}
    func isOverheated(cutoff: ThermalCutoff) -> Bool { false }
    func start(cutoff: ThermalCutoff, onOverheated: @escaping () -> Void) {}
    func lockScreen() {}
    func preparePermissionIfNeeded() {}
    func send(title: String, body: String) {}
    func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
    func currentStatus() -> CLIInstallStatus { .unavailable }
    func install(completion: @escaping (Result<String, Error>) -> Void) {
        completion(.failure(NSError(domain: "SleepSkip.Isolated", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Installation is disabled in isolated mode."])))
    }
    func connect() throws {}
    func disconnect() throws {}
}
