import Foundation
import IOKit.ps
import SleepSkipCore

/// Keeps lid-close sleep suppressed without any authorization.
///
/// Event-driven only: the flag is re-armed when the power source changes, which is the one
/// transition that can clear it. No timer runs while a session is active — re-arming once a
/// second was implemented and measured, and it changed nothing: the machine still slept 7 s
/// after a cable was reconnected, because powerd had already committed to the decision by
/// then. Keeping the timer would have broken the "no timers while the panel is closed"
/// promise for no benefit.
///
/// Known gap, stated in the UI: with the lid already shut, **plugging the cable back in**
/// sleeps the machine 6–9 s later. powerd's power-change path re-evaluates the lid without
/// consulting selector 12. Unplugging is unaffected. Never Sleep has the identical limit; the
/// privileged `pmset` path does not, which is why `ClosedLidStrategy` offers both.
final class UnprivilegedLidGuard: ClosedLidGuarding {
    private var runLoopSource: CFRunLoopSource?
    private var isActive = false

    var isEngaged: Bool { isActive }

    func enable(completion: @escaping (Result<Void, Error>) -> Void) {
        disable()

        guard ClamshellFlag.setLidSleepSuppressed(true) else {
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
        completion(.success(()))
    }

    func disable() {
        isActive = false
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = nil
        }
        ClamshellFlag.setLidSleepSuppressed(false)
    }

    /// A leftover flag would keep the Mac awake after a crash. The flag is process-independent,
    /// so a relaunch simply re-arms it.
    deinit {
        ClamshellFlag.setLidSleepSuppressed(false)
    }

    private func startPowerSourceObserver() {
        let unmanagedSelf = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let guardObject = Unmanaged<UnprivilegedLidGuard>.fromOpaque(context).takeUnretainedValue()
            guard guardObject.isActive else { return }
            ClamshellFlag.setLidSleepSuppressed(true)
        }, unmanagedSelf)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
    }
}
