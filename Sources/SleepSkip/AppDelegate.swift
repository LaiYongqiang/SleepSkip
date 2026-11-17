import Cocoa
import Combine
import Darwin
import Foundation
import SleepSkipCore
import SwiftUI

enum IPCNotifications {
    static let openPopover = Notification.Name("io.github.laiyongqiang.SleepSkip.OpenPopover")
    static let cliStarted = Notification.Name("io.github.laiyongqiang.SleepSkip.CLIStarted")
    static let cliStopped = Notification.Name("io.github.laiyongqiang.SleepSkip.CLIStopped")
    static let controlCommand = Notification.Name("io.github.laiyongqiang.SleepSkip.ControlCommand")
    static let hookEvent = Notification.Name("io.github.laiyongqiang.SleepSkip.HookEvent")
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private var popoverPinObservers: [NSObjectProtocol] = []
    private var isParkingPopover = false
    private var displayTimer: Timer?
    private var keyMonitor: Any?
    private var sigTermSource: DispatchSourceSignal?
    private var sigIntSource: DispatchSourceSignal?
    private var cliProcessSources: [Int32: DispatchSourceProcess] = [:]
    private var cliWatchGenerations: [Int32: UUID] = [:]
    private var externalCLISessions: [Int32: ExternalCLISession] = [:]
    private var hookProcessSources: [String: DispatchSourceProcess] = [:]
    private var hookWatchGenerations: [String: UUID] = [:]
    private var hookCeilingWorkItem: DispatchWorkItem?
    private var wakeObserver: NSObjectProtocol?
    private var agentMonitor: AgentActivityMonitor?
    private var agentMonitorGeneration = UUID()
    private var globalHotKeyMonitor: GlobalHotKeyMonitor?
    /// False when this process is a duplicate that never took ownership of any session state.
    /// Guards teardown so a duplicate's exit cannot stop the primary instance's session.
    private var didStartPrimaryInstance = false
    private var pendingURLs: [URL] = []
    private var pendingOpenRequest = false
    private var isTerminating = false
    private let layoutModel = PopoverLayoutModel()
    private var popoverResizeCancellables: Set<AnyCancellable> = []
    private var pendingResizeScheduled = false

    private let isolatedSuiteName: String?
    private lazy var store: PreferencesStore = {
        if let suite = isolatedSuiteName, let defaults = UserDefaults(suiteName: suite) {
            let result = PreferencesStore(defaults: defaults)
            result.hasShownOnboarding = true
            result.hasSeenAutoFollowNotice = true
            return result
        }
        PreferencesStore.migrateFromLegacyDomainIfNeeded(defaults: UserDefaults(suiteName: "io.github.laiyongqiang.SleepSkip") ?? .standard)
        return PreferencesStore()
    }()
    // Deferred until the duplicate-instance check grants ownership. Even constructing a manager
    // writes runtime state and performs system reads, so rejected launches must never create it.
    lazy var sessionManager: SessionManager = {
        if isolatedSuiteName != nil {
            let inert = IsolatedSystemServices()
            return SessionManager(store: store, caffeinateRunner: inert, backpackGuard: inert,
                unprivilegedLidGuard: inert, powerMonitor: inert, thermalMonitor: inert,
                screenLocker: inert, notifier: inert, loginItem: inert, cliInstaller: inert,
                claudeHookController: inert, runtimeStateURL: nil, checkStaleSleepOnInit: false)
        }
        return SessionManager(store: store, caffeinateRunner: CaffeinateRunner(),
            backpackGuard: BackpackGuard(), unprivilegedLidGuard: UnprivilegedLidGuard(),
            powerMonitor: PowerMonitor(), thermalMonitor: ThermalMonitor(), screenLocker: ScreenLocker(),
            notifier: NativeNotifier(), loginItem: LoginItemManager(), cliInstaller: CLICommandInstaller(),
            claudeHookController: ClaudeCodeHookManager(), runtimeStateURL: RuntimeStateSnapshot.defaultURL,
            checkStaleSleepOnInit: true)
    }()

    override init() {
        isolatedSuiteName = CommandLine.arguments.contains("--isolated")
            ? "io.github.laiyongqiang.SleepSkip.isolated.\(ProcessInfo.processInfo.processIdentifier)" : nil
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if terminateIfDuplicateInstance() {
            // A duplicate must not tear down the primary's state on the way out: terminating here
            // runs `applicationWillTerminate`, which calls `stopSession` and would disable the
            // primary instance's backpack guard. Nothing was started by this instance, so skip
            // teardown entirely.
            didStartPrimaryInstance = false
            NSApp.terminate(nil)
            return
        }
        didStartPrimaryInstance = true

        NSApp.setActivationPolicy(.accessory)
        setupSignalHandlers()
        setupDistributedNotifications()
        setupWorkspaceNotifications()
        setupStatusItem()
        setupKeyboardShortcuts()

        configureSessionCallbacks()
        // A crash or force-quit can leave the lid guard script running with `disablesleep 1`
        // and no sentinel watching it. Clean that up before anything else reads power state.
        if isolatedSuiteName == nil {
            BackpackGuard.terminateDetachedGuard()
        }
        if CommandLine.arguments.contains("--no-auto-follow") {
            sessionManager.setAutoFollowEnabled(false)
        }
        sessionManager.setAgentSources(availableAgentSources)
        sessionManager.presentAutoFollowNoticeIfNeeded(hasDismissed: store.hasSeenAutoFollowNotice)
        if sessionManager.isAutoFollowEnabled {
            applyAutoFollow(true)
        }
        if isolatedSuiteName == nil, sessionManager.config.globalShortcutEnabled {
            applyGlobalShortcut(true)
        }

        updateStatusItemAppearance(
            active: sessionManager.isEffectivelyActive,
            closedLid: sessionManager.activeClosedLid
        )

        let shouldOpen = pendingOpenRequest || CommandLine.arguments.contains("--open") || !store.hasShownOnboarding
        store.hasShownOnboarding = true
        if shouldOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.showPopover() }
        }
        let urls = pendingURLs
        pendingURLs.removeAll()
        application(NSApp, open: urls)
    }

    func configureSessionCallbacks() {
        sessionManager.onStateChange = { [weak self] active, closedLid in
            self?.updateStatusItemAppearance(active: active, closedLid: closedLid)
            if !active, self?.sessionManager.hasActiveHookSessions == false {
                self?.clearHookWatchdogs()
            } else {
                self?.scheduleHookCeilingIfNeeded()
            }
        }
        sessionManager.onRequestClosePopover = { [weak self] in
            self?.closePopover()
        }
        sessionManager.onAutoFollowToggled = { [weak self] enabled in
            self?.applyAutoFollow(enabled)
        }
        sessionManager.onAgentSourcesConfigChanged = { [weak self] in
            guard let self else { return }
            self.sessionManager.setAgentSources(self.availableAgentSources)
            if self.sessionManager.isAutoFollowEnabled {
                self.applyAutoFollow(true)
            }
        }
        sessionManager.onGlobalShortcutToggled = { [weak self] enabled in
            self?.applyGlobalShortcut(enabled)
        }
        sessionManager.onAutoFollowNoticeDismissed = { [weak self] in
            self?.store.hasSeenAutoFollowNotice = true
        }
    }

    /// Clicking the app in Finder or Dock while it is already running. Without this, a menu bar
    /// app (`.accessory` activation policy) simply does nothing — there is no window to bring
    /// forward, so the launch appears to have been ignored.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard didStartPrimaryInstance else { pendingOpenRequest = true; return true }
        showPopover()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard didStartPrimaryInstance else { pendingURLs.append(contentsOf: urls); return }
        for url in urls {
            guard let command = URLCommandParser.parse(url) else { continue }
            sessionManager.applyURLCommand(command)
            if case .open = command {
                showPopover()
            }
        }
    }

    private func terminateIfDuplicateInstance() -> Bool {
        if CommandLine.arguments.contains("--isolated") {
            return false
        }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != currentPID }
            if !others.isEmpty {
                DistributedNotificationCenter.default().postNotificationName(
                    IPCNotifications.openPopover,
                    object: nil,
                    userInfo: nil,
                    deliverImmediately: true
                )
                return true
            }
        }
        return false
    }

    private func setupDistributedNotifications() {
        guard isolatedSuiteName == nil else { return }
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            self,
            selector: #selector(handleExternalOpenRequest),
            name: IPCNotifications.openPopover,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleCLIStarted(_:)),
            name: IPCNotifications.cliStarted,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleCLIStopped(_:)),
            name: IPCNotifications.cliStopped,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleControlCommand(_:)),
            name: IPCNotifications.controlCommand,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleHookEvent(_:)),
            name: IPCNotifications.hookEvent,
            object: nil
        )
    }

    private func applyGlobalShortcut(_ enabled: Bool) {
        globalHotKeyMonitor?.stop()
        globalHotKeyMonitor = nil
        guard enabled, isolatedSuiteName == nil else { return }

        let monitor = GlobalHotKeyMonitor()
        monitor.start { [weak self] in
            self?.sessionManager.applyURLCommand(.toggle)
        }
        globalHotKeyMonitor = monitor
    }

    private func applyAutoFollow(_ enabled: Bool) {
        agentMonitorGeneration = UUID()
        let generation = agentMonitorGeneration
        agentMonitor?.stop()
        agentMonitor = nil
        sessionManager.agentTracker.reset()
        sessionManager.handleAgentActivity(.inactive)
        guard enabled else { return }

        let monitor = AgentActivityMonitor(
            tracker: sessionManager.agentTracker,
            onStateChange: { [weak self] state in
                DispatchQueue.main.async {
                    guard let self, self.agentMonitorGeneration == generation else { return }
                    self.sessionManager.handleAgentActivity(state)
                }
            },
            onSessionLimitReached: { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.agentMonitorGeneration == generation else { return }
                    self.sessionManager.handleAutoFollowLimitReached()
                }
            },
            onSourcesChanged: { [weak self] sources in
                DispatchQueue.main.async {
                    guard let self, self.agentMonitorGeneration == generation else { return }
                    self.sessionManager.setAgentSources(sources)
                }
            }
        )
        monitor.start(sources: configuredAgentSources)
        agentMonitor = monitor
    }

    /// Enabled built-in and custom sources whose directories exist on this machine.
    private var configuredAgentSources: [AgentSource] {
        AgentSource.configured(
            disabledSourceIDs: sessionManager.config.disabledAgentSourceIDs,
            customPaths: sessionManager.config.customAgentPaths
        )
    }

    private var availableAgentSources: [AgentSource] {
        configuredAgentSources.filter {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &directory) && directory.boolValue
        }
    }

    private func refreshAvailableAgentSourcesIfChanged() {
        let updated = availableAgentSources
        guard updated.map(\.path) != sessionManager.agentSources.map(\.path) else { return }
        sessionManager.setAgentSources(updated)
        if sessionManager.isAutoFollowEnabled {
            applyAutoFollow(true)
        }
    }

    private func setupWorkspaceNotifications() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sessionManager.reconcileOnWakeOrShow()
        }
    }

    @objc private func handleExternalOpenRequest() {
        DispatchQueue.main.async {
            self.showPopover()
        }
    }

    @objc private func handleCLIStarted(_ notification: Notification) {
        guard let info = notification.userInfo,
              let pidNum = info["pid"] as? NSNumber else { return }
        let pid = pidNum.int32Value
        let name = (info["cmd"] as? String) ?? "cli"
        let modeRaw = (info["mode"] as? String) ?? GuardMode.background.rawValue
        let mode = GuardMode(rawValue: modeRaw) ?? .background

        DispatchQueue.main.async {
            guard pid > 0, kill(pid, 0) == 0 else { return }
            self.externalCLISessions[pid] = ExternalCLISession(pid: pid, commandName: name, mode: mode)
            self.watchExternalCLIPID(pid)
            self.refreshExternalCLIRepresentative()
        }
    }

    @objc private func handleCLIStopped(_ notification: Notification) {
        guard let pid = (notification.userInfo?["pid"] as? NSNumber)?.int32Value else { return }
        DispatchQueue.main.async { self.removeExternalCLI(pid: pid) }
    }

    @objc private func handleControlCommand(_ notification: Notification) {
        guard let action = notification.userInfo?["action"] as? String else { return }
        DispatchQueue.main.async {
            switch action {
            case "stop":
                self.sessionManager.applyURLCommand(.stop)
            case "toggle":
                self.sessionManager.applyURLCommand(.toggle)
            case "lock":
                self.sessionManager.applyURLCommand(.lock)
            default:
                break
            }
        }
    }

    @objc private func handleHookEvent(_ notification: Notification) {
        guard let info = notification.userInfo,
              let actionRaw = info["action"] as? String,
              let action = HookAction(rawValue: actionRaw) else { return }
        let agent = (info["agent"] as? String) ?? "claude-code"
        let sessionID = (info["sessionID"] as? String) ?? "default:\(agent)"
        let pid = (info["pid"] as? NSNumber)?.int32Value ?? 0

        DispatchQueue.main.async {
            switch action {
            case .start:
                self.sessionManager.handleHookStart(sessionID: sessionID, agent: agent)
                if pid > 0 {
                    self.watchHookPID(pid, sessionID: sessionID, agent: agent)
                }
                self.scheduleHookCeilingIfNeeded()
            case .stop:
                self.stopWatchingHookPID(sessionID: sessionID, agent: agent)
                self.sessionManager.handleHookStop(sessionID: sessionID, agent: agent, reasonCode: "hookStop")
                self.scheduleHookCeilingIfNeeded()
            case .install, .uninstall:
                break
            }
        }
    }

    /// Pure kernel kqueue monitor (zero polling) so a crashed hooked process releases its lease.
    private func watchHookPID(_ pid: Int32, sessionID: String, agent: String) {
        stopWatchingHookPID(sessionID: sessionID, agent: agent)
        guard pid > 0, kill(pid, 0) == 0 else {
            sessionManager.handleHookStop(sessionID: sessionID, agent: agent, reasonCode: "hookStop")
            return
        }
        let key = hookWatchKey(sessionID: sessionID, agent: agent)
        let generation = UUID()
        hookWatchGenerations[key] = generation
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, self.hookWatchGenerations[key] == generation else { return }
            self.stopWatchingHookPID(sessionID: sessionID, agent: agent)
            self.sessionManager.handleHookStop(sessionID: sessionID, agent: agent, reasonCode: "hookStop")
            self.scheduleHookCeilingIfNeeded()
        }
        source.resume()
        hookProcessSources[hookWatchKey(sessionID: sessionID, agent: agent)] = source
    }

    private func hookWatchKey(sessionID: String, agent: String) -> String {
        // Include lengths so arbitrary session IDs cannot collide through a separator.
        let normalizedAgent = AgentSource.displayName(forIdentifier: agent).lowercased()
        return "\(normalizedAgent.utf8.count):\(normalizedAgent)\(sessionID)"
    }

    private func stopWatchingHookPID(sessionID: String, agent: String) {
        let key = hookWatchKey(sessionID: sessionID, agent: agent)
        hookWatchGenerations.removeValue(forKey: key)
        hookProcessSources.removeValue(forKey: key)?.cancel()
    }

    private func scheduleHookCeilingIfNeeded() {
        cancelHookCeiling()
        guard !isTerminating else { return }
        let automaticDeadline = sessionManager.isFollowingAgents ? sessionManager.endDate : nil
        let deadlines = [sessionManager.nextHookLeaseExpirationDate, automaticDeadline].compactMap { $0 }
        guard let expiration = deadlines.min() else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hookCeilingWorkItem = nil
            if self.sessionManager.isFollowingAgents,
               let deadline = self.sessionManager.endDate, deadline <= Date() {
                self.sessionManager.handleAutoFollowLimitReached()
            }
            for lease in self.sessionManager.expireHookLeases() {
                self.stopWatchingHookPID(sessionID: lease.sessionID, agent: lease.agent)
            }
            self.scheduleHookCeilingIfNeeded()
        }
        hookCeilingWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.02, expiration.timeIntervalSinceNow), execute: work)
    }

    private func cancelHookCeiling() {
        hookCeilingWorkItem?.cancel()
        hookCeilingWorkItem = nil
    }

    private func clearHookWatchdogs() {
        for source in hookProcessSources.values {
            source.cancel()
        }
        hookProcessSources.removeAll()
        hookWatchGenerations.removeAll()
        scheduleHookCeilingIfNeeded()
    }

    /// Pure kernel kqueue monitor (zero polling / 0% CPU) that cleans up CLI badge if CLI terminates abnormally.
    private func watchExternalCLIPID(_ pid: Int32) {
        cliProcessSources.removeValue(forKey: pid)?.cancel()
        let generation = UUID()
        cliWatchGenerations[pid] = generation
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, self.cliWatchGenerations[pid] == generation else { return }
            self.removeExternalCLI(pid: pid)
        }
        cliProcessSources[pid] = source
        source.resume()
    }

    private func removeExternalCLI(pid: Int32) {
        cliWatchGenerations.removeValue(forKey: pid)
        cliProcessSources.removeValue(forKey: pid)?.cancel()
        externalCLISessions.removeValue(forKey: pid)
        refreshExternalCLIRepresentative()
    }

    private func refreshExternalCLIRepresentative() {
        if let current = sessionManager.externalCLI, let updated = externalCLISessions[current.pid] {
            sessionManager.setExternalCLISession(updated)
        } else {
            sessionManager.setExternalCLISession(externalCLISessions.values.sorted { $0.pid < $1.pid }.first)
        }
    }

    private func stopWatchingExternalCLI() {
        for source in cliProcessSources.values { source.cancel() }
        cliProcessSources.removeAll()
        cliWatchGenerations.removeAll()
        externalCLISessions.removeAll()
    }

    private func setupSignalHandlers() {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler {
            NSApp.terminate(nil)
        }
        term.resume()
        sigTermSource = term

        let intr = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intr.setEventHandler {
            NSApp.terminate(nil)
        }
        intr.resume()
        sigIntSource = intr
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleStatusBarClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @discardableResult
    private func ensurePopover() -> NSPopover {
        if let popover {
            return popover
        }
        let popover = NSPopover()
        popover.behavior = .transient
        // Disable AppKit's built-in popover transition so SwiftUI content appears cleanly without horizontal clipping.
        popover.animates = false
        popover.delegate = self

        let rootView = SleepSkipPopoverView(manager: sessionManager, layoutModel: layoutModel)
        let hostingView = NSHostingView(rootView: rootView)
        let controller = NSViewController()
        controller.view = hostingView
        popover.contentViewController = controller

        sessionManager.objectWillChange
            .sink { [weak self] _ in self?.schedulePopoverResize() }
            .store(in: &popoverResizeCancellables)
        layoutModel.objectWillChange
            .sink { [weak self] _ in self?.schedulePopoverResize() }
            .store(in: &popoverResizeCancellables)

        self.popover = popover
        return popover
    }

    private func schedulePopoverResize() {
        guard !pendingResizeScheduled, popover?.isShown == true else { return }
        pendingResizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingResizeScheduled = false
            guard self.popover?.isShown == true else { return }
            self.applyPopoverFittingSize()
        }
    }

    private func applyPopoverFittingSize() {
        guard let popover, let view = popover.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize
        guard fitting.width > 0, fitting.height > 0 else { return }
        if abs(popover.contentSize.width - fitting.width) > 1 || abs(popover.contentSize.height - fitting.height) > 1 {
            popover.contentSize = fitting
        }
    }

    private func setupKeyboardShortcuts() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover?.isShown == true else { return event }

            // Cmd + , -> toggle settings
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "," {
                self.sessionManager.refreshClaudeHookStatus()
                self.sessionManager.showSettings.toggle()
                return nil
            }

            // Cmd + Q -> clean quit
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "q" {
                self.sessionManager.stopSession(reason: .silent)
                NSApp.terminate(nil)
                return nil
            }

            // Esc -> back or close popover
            if event.keyCode == 53 {
                if self.sessionManager.showSettings {
                    self.sessionManager.showSettings = false
                } else if self.sessionManager.showCustomInput {
                    self.sessionManager.showCustomInput = false
                } else {
                    self.closePopover()
                }
                return nil
            }

            // Return / NumPad Enter
            if event.keyCode == 36 || event.keyCode == 76 {
                if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView {
                    return event
                }
                if self.sessionManager.showSettings {
                    return event
                }
                if self.sessionManager.isAuthorizing {
                    return nil
                }
                if self.sessionManager.isRunning && !self.sessionManager.isFollowingAgents {
                    self.closePopover()
                } else {
                    self.sessionManager.startConfiguredSession()
                }
                return nil
            }

            return event
        }
    }

    @objc private func handleStatusBarClick(_ sender: NSStatusBarButton) {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
            return
        }
        togglePopover()
    }

    func togglePopover() {
        if popover?.isShown == true {
            closePopover()
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        let popover = ensurePopover()
        sessionManager.reconcileOnWakeOrShow()
        sessionManager.refreshStaleSleepState()
        sessionManager.refreshCLIInstallStatus()
        sessionManager.refreshClaudeHookStatus()
        refreshAvailableAgentSourcesIfChanged()

        let screen = button.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let availableHeight = screen?.visibleFrame.height ?? 720
        let cappedHeight = min(620, max(340, floor(availableHeight - 72)))
        if abs(layoutModel.maxPopoverHeight - cappedHeight) > 1 {
            layoutModel.maxPopoverHeight = cappedHeight
        }

        applyPopoverFittingSize()

        NSApp.activate(ignoringOtherApps: true)

        // Menu bar managers (Ice, Bartender, Icey, Hidden Bar, …) can move an item into a hidden
        // section that parks its window far off-screen. Anchoring there makes AppKit clamp the
        // popover to the nearest display edge, which looks broken. Detect the cause — the anchor
        // being off-screen — rather than the symptom, so an item legitimately placed at the left
        // end of the bar still gets a normally anchored popover.
        removePopoverPinObservers()
        let anchorIsOffScreen = statusItemIsOffScreen(button)

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        guard anchorIsOffScreen else {
            startDisplayTimer()
            return
        }
        if let popoverWindow = popover.contentViewController?.view.window {
            installPopoverPinObservers(for: popoverWindow)
        }
        // NSPopover finishes positioning asynchronously after `show`, so correct it on the next
        // runloop turn rather than immediately.
        DispatchQueue.main.async { [weak self] in
            self?.parkPopoverAtScreenCorner()
        }
        startDisplayTimer()
    }

    /// Keeps an off-screen-anchored popover pinned at the top-right corner when AppKit
    /// repositions it after a SwiftUI content size change (e.g. entering or leaving Settings).
    private func installPopoverPinObservers(for window: NSWindow) {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didMoveNotification
        ]
        popoverPinObservers = names.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                guard let self, !self.isParkingPopover,
                      let button = self.statusItem?.button,
                      self.statusItemIsOffScreen(button) else { return }
                self.parkPopoverAtScreenCorner()
            }
        }
    }

    private func removePopoverPinObservers() {
        let center = NotificationCenter.default
        for observer in popoverPinObservers {
            center.removeObserver(observer)
        }
        popoverPinObservers.removeAll()
    }

    /// True when the status item's own window is not on any visible display.
    private func statusItemIsOffScreen(_ button: NSStatusBarButton) -> Bool {
        guard let window = button.window else { return true }
        let frame = window.frame
        // A hidden item can be parked thousands of points away, but some managers only shift it
        // by a few hundred, so check intersection rather than a fixed threshold.
        return !NSScreen.screens.contains { $0.frame.intersects(frame) }
    }

    /// Places the panel just inside the top-right of the visible area when the status item
    /// itself is off-screen (e.g. hidden by a menu bar manager).
    private func parkPopoverAtScreenCorner() {
        guard !isParkingPopover,
              let popoverWindow = popover?.contentViewController?.view.window,
              let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let visible = screen.visibleFrame
        var frame = popoverWindow.frame
        let targetX = visible.maxX - frame.width - 12
        let targetY = visible.maxY - frame.height - 12
        guard abs(frame.origin.x - targetX) > 1 || abs(frame.origin.y - targetY) > 1 else { return }
        frame.origin.x = targetX
        frame.origin.y = targetY
        isParkingPopover = true
        popoverWindow.setFrame(frame, display: true, animate: false)
        isParkingPopover = false
    }

    func closePopover() {
        popover?.performClose(nil)
        stopDisplayTimer()
    }

    private func showContextMenu() {
        let t = sessionManager.l10n
        let menu = NSMenu()

        let openItem = NSMenuItem(title: t.menuOpenPanel, action: #selector(menuOpenPanel), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        if sessionManager.isAuthorizing {
            let cancelItem = NSMenuItem(title: t.cancelLaunchButton, action: #selector(menuCancelAuthorization), keyEquivalent: "")
            cancelItem.target = self
            menu.addItem(cancelItem)
        } else if sessionManager.isFollowingAgents {
            let startItem = NSMenuItem(title: t.menuQuickStart, action: #selector(menuQuickStart), keyEquivalent: "")
            startItem.target = self
            menu.addItem(startItem)

            let stopItem = NSMenuItem(title: t.autoFollowStopButton, action: #selector(menuStop), keyEquivalent: "")
            stopItem.target = self
            menu.addItem(stopItem)
        } else if sessionManager.isRunning {
            let stopItem = NSMenuItem(title: t.menuStop, action: #selector(menuStop), keyEquivalent: "")
            stopItem.target = self
            menu.addItem(stopItem)
        } else {
            let startItem = NSMenuItem(title: t.menuQuickStart, action: #selector(menuQuickStart), keyEquivalent: "")
            startItem.target = self
            menu.addItem(startItem)
        }

        let lockItem = NSMenuItem(title: t.lockScreenButton, action: #selector(menuLockScreen), keyEquivalent: "")
        lockItem.target = self
        menu.addItem(lockItem)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: t.launchAtLoginLabel, action: #selector(menuToggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = sessionManager.launchAtLogin ? .on : .off
        menu.addItem(loginItem)

        let settingsItem = NSMenuItem(title: t.settingsTitle, action: #selector(menuOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: t.quitButton, action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuOpenPanel() {
        sessionManager.showSettings = false
        showPopover()
    }

    @objc private func menuQuickStart() {
        sessionManager.startConfiguredSession()
    }

    @objc private func menuStop() {
        sessionManager.stopSession(reason: .manual)
    }

    @objc private func menuCancelAuthorization() {
        sessionManager.cancelAuthorization()
    }

    @objc private func menuLockScreen() {
        sessionManager.applyURLCommand(.lock)
    }

    @objc private func menuToggleLaunchAtLogin() {
        sessionManager.toggleLaunchAtLogin(!sessionManager.launchAtLogin)
    }

    @objc private func menuOpenSettings() {
        sessionManager.showSettings = true
        showPopover()
    }

    @objc private func menuQuit() {
        sessionManager.stopSession(reason: .silent)
        NSApp.terminate(nil)
    }

    // MARK: - NSPopoverDelegate (Event-driven display timer)

    func popoverWillShow(_ notification: Notification) {
        sessionManager.reconcileOnWakeOrShow()
        startDisplayTimer()
    }

    func popoverDidClose(_ notification: Notification) {
        stopDisplayTimer()
        removePopoverPinObservers()
        // The first-run notice has been shown; do not bring it back on the next open.
        sessionManager.retireAutoFollowNoticeOnPanelClose()
    }

    private func startDisplayTimer() {
        stopDisplayTimer()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.popover?.isShown == true else { return }
            self.sessionManager.refreshDisplayTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func updateStatusItemAppearance(active: Bool, closedLid: Bool) {
        guard let button = statusItem?.button else { return }
        if active && closedLid {
            let img = NSImage(systemSymbolName: "lock.laptopcomputer", accessibilityDescription: sessionManager.l10n.appName)
            img?.isTemplate = true
            button.image = img
        } else {
            button.image = StatusBarIcon.image(active: active)
        }

        let t = sessionManager.l10n
        if sessionManager.isAuthorizing {
            button.toolTip = "\(t.appName) — \(t.authorizingTitle)"
        } else if sessionManager.isRunning {
            let modeTxt = t.modeTitle(sessionManager.activeMode)
            let lidTxt = closedLid ? " · \(t.backpackBadge)" : ""
            button.toolTip = "\(t.appName) — \(t.runningBadge) (\(modeTxt)\(lidTxt))"
        } else if let cli = sessionManager.externalCLI {
            button.toolTip = "\(t.appName) — \(t.cliGuardingBanner(cli))"
        } else {
            button.toolTip = "\(t.appName) — \(t.idleBadge)"
        }
        button.setAccessibilityLabel(button.toolTip)
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard didStartPrimaryInstance else { return }
        isTerminating = true
        agentMonitorGeneration = UUID()
        agentMonitor?.stop()
        agentMonitor = nil
        DistributedNotificationCenter.default().removeObserver(self)
        clearHookWatchdogs()
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        stopWatchingExternalCLI()
        stopDisplayTimer()
        globalHotKeyMonitor?.stop()
        globalHotKeyMonitor = nil
        // A duplicate instance never started anything; stopping here would disable the guard the
        // primary instance is relying on.
        guard didStartPrimaryInstance else { return }
        sessionManager.stopSession(reason: .silent)
        sessionManager.clearRuntimeStateSnapshot()
        if let isolatedSuiteName {
            UserDefaults(suiteName: isolatedSuiteName)?.removePersistentDomain(forName: isolatedSuiteName)
        }
    }
}
