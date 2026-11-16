import Darwin
import Foundation

/// Bounded hook JSON input; only session_id is returned, never prompt/tool contents.
public enum CLIHookInput {
    public enum InputError: LocalizedError {
        case timeout, oversized, invalid, readFailed
        public var errorDescription: String? {
            switch self {
            case .timeout: return "Hook stdin did not reach EOF within the input deadline. Close stdin or pass --session <id>."
            case .oversized: return "Hook stdin exceeds the input limit. Pass --session <id> instead."
            case .invalid: return "Hook stdin must be a JSON object with a nonempty string session_id. Pass --session <id> instead."
            case .readFailed: return "Could not read hook stdin. Pass --session <id> instead."
            }
        }
    }

    /// A terminal or empty EOF has no payload. An open pipe must reach EOF within two
    /// seconds; partial, malformed, missing-identity and oversized input are errors.
    public static func readSessionID(fd: Int32 = STDIN_FILENO, timeout: TimeInterval = 2, maximumBytes: Int = 1_048_576) throws -> String? {
        guard isatty(fd) == 0 else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw InputError.timeout }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1000 + 1, Double(Int32.max))))
            if result < 0, errno == EINTR { continue }
            guard result >= 0 else { throw InputError.readFailed }
            if result == 0 { throw InputError.timeout }
            guard descriptor.revents & Int16(POLLNVAL | POLLERR) == 0 else { throw InputError.readFailed }
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw InputError.readFailed }
            if count == 0 { break }
            guard count <= maximumBytes - data.count else { throw InputError.oversized }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard !data.isEmpty else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["session_id"] as? String else { throw InputError.invalid }
        let identity = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identity.isEmpty else { throw InputError.invalid }
        return identity
    }
}
