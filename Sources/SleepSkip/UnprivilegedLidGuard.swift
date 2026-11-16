import Cocoa
import Foundation
import IOKit.ps
import SleepSkipCore

/// Suppresses lid-close sleep without any authorization.
///
/// Sets `kPMSetClamshellSleepState` (selector 12) and keeps it armed across power-source
/// changes, display sleep, system wake, and a low-frequency periodic timer while active, since
/// `powerd` can silently clear the selector over time or when the display turns off.
///
/// Known limit: with the lid already shut, **plugging the cable back in** sleeps the machine
/// 6–9 s later because `powerd`'s power-change path re-evaluates the lid without consulting
/// selector 12. Unplugging is unaffected. The privileged `pmset` path does not have this limit.
final class UnprivilegedLidGuard: ClosedLidGuarding {
    private static let rearmInterval: TimeInterval = 5.0

    private var runLoopSource: CFRunLoopSource?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var rearmTimer: Timer?
    private var isActive = false
    private let setSuppressed: (Bool) -> Bool

    init(setSuppressed: @escaping (Bool) -> Bool = { ClamshellFlag.setLidSleepSuppressed($0) }) {
        self.setSuppressed = setSuppressed
    }

    var isEngaged: Bool { isActive }

    func enable(completion: @escaping (Result<Void, Error>) -> Void) {
        disable()

        guard setSuppressed(true) else {
            completion(.failure(NSError(
                domain: "SleepSkip.UnprivilegedLidGuard",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "The system rejected the lid-sleep request. Try the privileged mode instead."]
            )))
            return
        }

        isActive = true
        startPowerSourceObserver()
        startWorkspaceObservers()
        startRearmTimer()
        completion(.success(()))
    }

    func disable() {
        let wasEngaged = isActive
        isActive = false
        rearmTimer?.invalidate()
        rearmTimer = nil
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = nil
        }
        if wasEngaged { _ = setSuppressed(false) }
    }

    deinit { disable() }

    private func rearmIfActive() {
        guard isActive else { return }
        _ = setSuppressed(true)
    }

    private func startPowerSourceObserver() {
        let unmanagedSelf = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let guardObject = Unmanaged<UnprivilegedLidGuard>.fromOpaque(context).takeUnretainedValue()
            guardObject.rearmIfActive()
        }, unmanagedSelf)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
    }

    private func startWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.didWakeNotification
        ]
        workspaceObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.rearmIfActive()
            }
        }
    }

    private func startRearmTimer() {
        let timer = Timer(timeInterval: Self.rearmInterval, repeats: true) { [weak self] _ in
            self?.rearmIfActive()
        }
        timer.tolerance = 1.0
        RunLoop.main.add(timer, forMode: .common)
        rearmTimer = timer
    }
}
