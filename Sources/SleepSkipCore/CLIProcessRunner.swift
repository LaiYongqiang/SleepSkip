import Darwin
import Foundation

/// Native CLI process ownership. kqueue sleeps until a signal or process exit; no timer polling.
public enum CLIProcessRunner {
    public static func run(arguments: [String], assertionFlags: [String]) -> Int32 {
        do {
            let events = try ProcessEvents()
            let terminal = TerminalOwnership()
            let child = try spawn(["/usr/bin/env"] + arguments, suspended: true)
            var childReaped = false
            defer {
                if !childReaped {
                    kill(-child, SIGKILL)
                    var status: Int32 = 0
                    while waitpid(child, &status, 0) < 0, errno == EINTR {}
                }
            }
            // Spawn suspended so a terminal reader cannot race tcsetpgrp and stop on SIGTTIN.
            terminal.give(to: child)
            kill(child, SIGCONT)
            defer { terminal.restore() }
            let assertion: pid_t?
            do {
                assertion = try spawn(["/usr/bin/caffeinate"] + assertionFlags + ["-w", String(getpid())])
            } catch {
                assertion = nil
                fputs("SleepSkip CLI warning: sleep prevention unavailable (\(error.localizedDescription)); command will continue.\n", stderr)
            }
            defer { reapAssertion(assertion) }
            while true {
                var status: Int32 = 0
                let result = waitpid(child, &status, WNOHANG | WUNTRACED)
                if result == child {
                    if status & 0xff == 0x7f {
                        // Let the invoking shell regain its terminal while this job is stopped.
                        terminal.restore()
                        kill(getpid(), SIGSTOP)
                        terminal.give(to: child)
                        kill(-child, SIGCONT)
                    } else {
                        childReaped = true
                        return status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                    }
                } else if result < 0, errno != EINTR {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD)
                }
                guard let event = try events.next() else { continue }
                if event.filter == EVFILT_SIGNAL {
                    let number = Int32(event.ident)
                    if [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGTSTP].contains(number) {
                        kill(-child, number)
                    } else if number == SIGCONT {
                        terminal.give(to: child)
                        kill(-child, SIGCONT)
                    }
                }
            }
        } catch {
            fputs("SleepSkip CLI error: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    public static func watch(pid: Int32, assertionFlags: [String]) -> Int32 {
        do {
            let events = try ProcessEvents()
            guard try events.watch(pid: pid) else { return 0 }
            // The assertion belongs to this wrapper, not the unrelated target. Even SIGKILL
            // releases it via caffeinate's kernel process watcher, without touching the target.
            let assertion = try spawn(["/usr/bin/caffeinate"] + assertionFlags + ["-w", String(getpid())])
            defer { reapAssertion(assertion) }
            while true {
                guard let event = try events.next() else { continue }
                if event.filter == EVFILT_PROC { return 0 }
                if event.filter == EVFILT_SIGNAL {
                    let number = Int32(event.ident)
                    if [SIGINT, SIGTERM, SIGHUP, SIGQUIT].contains(number) { return 128 + number }
                    if number == SIGTSTP { kill(getpid(), SIGSTOP) }
                }
            }
        } catch {
            fputs("SleepSkip CLI error: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func spawn(_ arguments: [String], suspended: Bool = false) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        var result = posix_spawnattr_init(&attributes)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL) }
        defer { posix_spawnattr_destroy(&attributes) }
        var signals = sigset_t()
        sigemptyset(&signals)
        posix_spawnattr_setsigmask(&attributes, &signals)
        for number in ProcessEvents.signals + [SIGTTIN, SIGTTOU, SIGPIPE] { sigaddset(&signals, number) }
        posix_spawnattr_setsigdefault(&attributes, &signals)
        posix_spawnattr_setpgroup(&attributes, 0)
        var flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        if suspended { flags |= Int16(POSIX_SPAWN_START_SUSPENDED) }
        posix_spawnattr_setflags(&attributes, flags)
        let storage = arguments.map { strdup($0)! }
        defer { storage.forEach { free($0) } }
        var argv: [UnsafeMutablePointer<CChar>?] = storage.map { $0 } + [nil]
        var pid: pid_t = 0
        result = posix_spawn(&pid, arguments[0], nil, &attributes, &argv, environ)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL) }
        return pid
    }

    private static func reapAssertion(_ pid: pid_t?) {
        guard let pid else { return }
        kill(pid, SIGTERM)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
    }
}

private final class ProcessEvents {
    static let signals = [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGTSTP, SIGCONT, SIGCHLD]
    private let descriptor: Int32
    private var saved: [(Int32, sigaction)] = []

    init() throws {
        descriptor = kqueue()
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        do {
            for number in Self.signals {
                var old = sigaction()
                sigaction(number, nil, &old)
                saved.append((number, old))
                // A real no-op handler retains waitpid status (SIGCHLD=SIG_IGN can auto-reap).
                signal(number) { _ in }
                var event = kevent(ident: UInt(number), filter: Int16(EVFILT_SIGNAL), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil)
                guard kevent(descriptor, &event, 1, nil, 0, nil) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
                }
            }
        } catch {
            restore()
            close(descriptor)
            throw error
        }
    }

    deinit { restore(); close(descriptor) }

    private func restore() {
        for (number, value) in saved {
            var value = value
            sigaction(number, &value, nil)
        }
    }

    func watch(pid: pid_t) throws -> Bool {
        var event = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT), fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        guard kevent(descriptor, &event, 1, nil, 0, nil) == 0 else {
            if errno == ESRCH { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
        return true
    }

    func next() throws -> kevent? {
        var event = kevent()
        let result = kevent(descriptor, nil, 0, &event, 1, nil)
        if result < 0 {
            if errno == EINTR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
        return event
    }
}

private final class TerminalOwnership {
    private let wrapperGroup = getpgrp()
    private var foregroundChild: pid_t = -1
    private let terminalFD: Int32
    private var saved: [(Int32, sigaction)] = []

    init() {
        // The command may read /dev/tty even when its stdin is redirected.
        terminalFD = open("/dev/tty", O_RDWR | O_CLOEXEC | O_NONBLOCK)
        if terminalFD >= 0 {
            for number in [SIGTTIN, SIGTTOU] {
                var old = sigaction()
                sigaction(number, nil, &old)
                saved.append((number, old))
                signal(number, SIG_IGN)
            }
        }
    }

    func give(to pid: pid_t) {
        // The shell may resume us with either `fg` or `bg`. Only hand off a terminal
        // which it has explicitly assigned to this wrapper; never steal it on `bg`.
        if tcgetpgrp(terminalFD) == wrapperGroup, tcsetpgrp(terminalFD, pid) == 0 {
            foregroundChild = pid
        }
    }

    func restore() {
        if foregroundChild > 0, tcgetpgrp(terminalFD) == foregroundChild {
            tcsetpgrp(terminalFD, wrapperGroup)
        }
        foregroundChild = -1
    }

    deinit {
        restore()
        if terminalFD >= 0 { close(terminalFD) }
        for (number, value) in saved {
            var value = value
            sigaction(number, &value, nil)
        }
    }
}
