import Foundation
import Testing
@testable import SleepSkipCore

@Suite("Agent Activity")
final class AgentActivityTests {
    private var clock: Date = Date(timeIntervalSince1970: 1_700_000_000)
    private func advance(_ seconds: TimeInterval) { clock = clock.addingTimeInterval(seconds) }

    private func makeTracker(
        policy: AgentActivityPolicy = AgentActivityPolicy(activityWindow: 30, gracePeriod: 300, maxAutoSessionDuration: 7200)
    ) -> AgentActivityTracker {
        AgentActivityTracker(policy: policy, nowProvider: { self.clock })
    }

    @Test func freshTrackerIsInactive() {
        #expect(makeTracker().evaluate() == .inactive)
    }

    @Test func recordedActivityIsActive() {
        let tracker = makeTracker()
        tracker.recordActivity(sourceID: "claude-code")
        guard case .active(let agents, let lastActivity) = tracker.evaluate() else {
            Issue.record("expected active")
            return
        }
        #expect(agents == ["claude-code"])
        #expect(lastActivity == clock)
        #expect(tracker.shouldHoldAssertion(for: tracker.evaluate()))
    }

    @Test func quietInsideWindowStaysActive() {
        let tracker = makeTracker()
        tracker.recordActivity(sourceID: "claude-code")
        advance(20)
        #expect(tracker.evaluate().isHolding)
    }

    @Test func quietPastWindowEntersGrace() {
        let tracker = makeTracker()
        tracker.recordActivity(sourceID: "claude-code")
        advance(60)
        guard case .grace = tracker.evaluate() else {
            Issue.record("expected grace")
            return
        }
        #expect(tracker.shouldHoldAssertion(for: tracker.evaluate()))
    }

    @Test func quietPastGraceReleases() {
        let tracker = makeTracker()
        tracker.recordActivity(sourceID: "claude-code")
        advance(30 + 300 + 1)
        #expect(tracker.evaluate() == .inactive)
        #expect(!tracker.shouldHoldAssertion(for: tracker.evaluate()))
    }

    @Test func parallelSessionsHoldWhileAnyIsActive() {
        let tracker = makeTracker()
        tracker.recordActivity(sourceID: "claude-code")
        advance(10)
        tracker.recordActivity(sourceID: "codex")
        advance(25) // claude-code is quiet, codex still active
        guard case .active(let agents, _) = tracker.evaluate() else {
            Issue.record("expected active")
            return
        }
        #expect(agents == ["codex"])
    }

    @Test func hardCeilingReleasesEvenWhenActive() {
        let tracker = makeTracker(policy: AgentActivityPolicy(activityWindow: 30, gracePeriod: 300, maxAutoSessionDuration: 120))
        // Keep the agent writing past the ceiling.
        for _ in 0..<10 {
            tracker.recordActivity(sourceID: "claude-code")
            advance(20)
        }
        #expect(tracker.autoSessionExceeded())
        #expect(!tracker.shouldHoldAssertion(for: tracker.evaluate()))

        // Hitting the ceiling must not disable auto-follow for the rest of the app's lifetime.
        tracker.restartSessionWindow()
        tracker.recordActivity(sourceID: "claude-code")
        #expect(!tracker.autoSessionExceeded())
        #expect(tracker.shouldHoldAssertion(for: tracker.evaluate()))
    }

    @Test func resetClearsSession() {
        let tracker = makeTracker()
        tracker.recordActivity(sourceID: "claude-code")
        advance(200)
        tracker.reset()
        #expect(tracker.evaluate() == .inactive)
        #expect(!tracker.autoSessionExceeded())
    }

    @Test func defaultSourcesPointAtTranscriptDirectories() {
        let home = URL(fileURLWithPath: "/Users/example")
        let sources = AgentSource.defaults(homeDirectory: home)
        #expect(sources.map(\.id) == ["claude-code", "codex", "dsh", "gemini-cli", "opencode"])
        #expect(sources[0].path == "/Users/example/.claude/projects")
        #expect(sources[2].path == "/Users/example/.dsh/sessions")
        #expect(sources[3].path == "/Users/example/.gemini/tmp")
        #expect(sources[4].path == "/Users/example/.local/share/opencode")
    }

    @Test func transcriptSuffixesArePerSource() {
        let home = URL(fileURLWithPath: "/Users/example")
        let sources = AgentSource.defaults(homeDirectory: home)
        let claude = sources[0]
        let dsh = sources[2]

        // DSH writes compressed transcripts, so a plain `.jsonl` check would miss it entirely.
        #expect(dsh.matches(filePath: "/Users/example/.dsh/sessions/p/session.v4.jsonl.zstd"))
        #expect(dsh.matches(filePath: "/Users/example/.dsh/sessions/p/s.jsonl"))
        #expect(!claude.matches(filePath: "/Users/example/.claude/projects/p/s.jsonl.zstd"))
        #expect(claude.matches(filePath: "/Users/example/.claude/projects/p/s.jsonl"))

        // A sibling directory sharing the prefix must not be attributed to the source.
        #expect(!dsh.matches(filePath: "/Users/example/.dsh/sessions-old/s.jsonl"))
    }
    @Test func freshTaskGetsANewCeilingAfterARealQuietInterval() {
        let tracker = makeTracker(policy: AgentActivityPolicy(activityWindow: 5, gracePeriod: 10, maxAutoSessionDuration: 30))
        tracker.recordActivity(sourceID: "Claude Code")
        advance(16)
        // No evaluate callback is required between tasks: the gap itself separates sessions.
        tracker.recordActivity(sourceID: "Codex")
        advance(16)
        #expect(!tracker.autoSessionExceeded())
        tracker.recordActivity(sourceID: "Codex")
        advance(31)
        #expect(tracker.evaluate() == .inactive)
        #expect(!tracker.autoSessionExceeded())
    }

    @Test func matchingResolvesSymlinksAndOnlyRejectsWholeNoiseDirectories() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ss-path-\(UUID().uuidString)")
        let target = base.appendingPathComponent("real")
        let link = base.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = AgentSource(id: "custom-original", displayName: "Custom", path: link.path, fileSuffixes: [])
        #expect(source.matches(filePath: target.appendingPathComponent("session.jsonl").path))
        #expect(source.matches(filePath: link.appendingPathComponent("project-node_modules/session.jsonl").path))
        #expect(!source.matches(filePath: link.appendingPathComponent("node_modules/session.jsonl").path))
        #expect(!source.matches(filePath: link.appendingPathComponent("../outside.jsonl").path))
        let temporarySource = AgentSource(id: "temp", displayName: "Temp", path: "/tmp/ss-path", fileSuffixes: [])
        #expect(temporarySource.matches(filePath: "/private/tmp/ss-path/session.txt"))
        #expect(source.id == "custom-original")
    }

    @Test func ceilingCheckDoesNotReportAnAlreadyQuietSession() {
        let tracker = makeTracker(policy: AgentActivityPolicy(activityWindow: 5, gracePeriod: 10, maxAutoSessionDuration: 30))
        tracker.recordActivity(sourceID: "codex")
        advance(31)
        // The monitor checks the ceiling before evaluating the display state.
        #expect(!tracker.autoSessionExceeded())
    }

}
