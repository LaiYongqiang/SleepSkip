import Darwin
import Foundation

/// Samples a process's cumulative CPU time and wakeup count over a fixed window.
///
/// Uses `proc_pid_rusage`, which reports the process's own usage — unlike `ps`, whose RSS
/// column also counts shared library pages and overstates a small app's memory several-fold.
///
///     swift scripts/bench_idle.swift <pid> [seconds]
///
/// Prints one line of machine-readable output so runs can be pasted side by side.

func sample(_ pid: pid_t) -> (cpuMillis: Double, wakeups: UInt64, idleWakeups: UInt64)? {
    var info = rusage_info_current()
    let status = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
            proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rebound)
        }
    }
    guard status == 0 else { return nil }

    let total = info.ri_user_time + info.ri_system_time
    // ri_*_time is in nanoseconds on macOS; fall back to treating it as microseconds if the
    // value is implausibly small, which is what an older libproc reports.
    let millis = total > 0 ? Double(total) / 1_000_000.0 : 0
    return (millis, info.ri_interrupt_wkups, info.ri_pkg_idle_wkups)
}

let arguments = CommandLine.arguments
var positional: [String] = []
var maxCpuMs: Double?
var maxWakeups: UInt64?

var idx = 1
while idx < arguments.count {
    let arg = arguments[idx]
    if arg == "--max-cpu-ms", idx + 1 < arguments.count {
        maxCpuMs = Double(arguments[idx + 1])
        idx += 2
    } else if arg == "--max-wakeups", idx + 1 < arguments.count {
        maxWakeups = UInt64(arguments[idx + 1])
        idx += 2
    } else {
        positional.append(arg)
        idx += 1
    }
}

guard !positional.isEmpty, let pid = pid_t(positional[0]) else {
    FileHandle.standardError.write(Data("usage: bench_idle <pid> [seconds] [--max-cpu-ms <ms>] [--max-wakeups <n>]\n".utf8))
    exit(2)
}
let seconds = positional.count >= 2 ? (Double(positional[1]) ?? 120) : 120

guard let before = sample(pid) else {
    FileHandle.standardError.write(Data("cannot read rusage for pid \(pid)\n".utf8))
    exit(3)
}

Thread.sleep(forTimeInterval: seconds)

guard let after = sample(pid) else {
    FileHandle.standardError.write(Data("process \(pid) exited during the measurement\n".utf8))
    exit(3)
}

let cpuDelta = after.cpuMillis - before.cpuMillis
let wakeupDelta = after.wakeups &- before.wakeups
let idleWakeupDelta = after.idleWakeups &- before.idleWakeups

print(String(
    format: "window=%.0fs cpu=%.3fms wakeups=%llu pkg_idle_wakeups=%llu",
    seconds, cpuDelta, wakeupDelta, idleWakeupDelta
))

if let maxCpuMs, cpuDelta > maxCpuMs {
    FileHandle.standardError.write(Data(String(format: "FAIL: idle CPU %.3fms exceeded gate %.3fms\n", cpuDelta, maxCpuMs).utf8))
    exit(1)
}

if let maxWakeups, wakeupDelta > maxWakeups {
    FileHandle.standardError.write(Data("FAIL: idle wakeups \(wakeupDelta) exceeded gate \(maxWakeups)\n".utf8))
    exit(1)
}
