import CoreServices
import Foundation
import Darwin
import SleepSkipCore

/// Event-driven transcript metadata watcher. All stream, source and timer state belongs to
/// eventQueue; callbacks retain a weak context rather than an unowned monitor pointer.
final class AgentActivityMonitor {
    private final class CallbackContext {
        weak var monitor: AgentActivityMonitor?
        init(_ monitor: AgentActivityMonitor) { self.monitor = monitor }
    }
    private let tracker: AgentActivityTracker
    private let onStateChange: (AgentActivityState) -> Void
    private let onSessionLimitReached: () -> Void
    private let onSourcesChanged: ([AgentSource]) -> Void
    private let eventQueue = DispatchQueue(label: "io.github.laiyongqiang.SleepSkip.fsevents")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var stream: FSEventStreamRef?
    private var sources: [AgentSource] = []
    private var availableSources: [AgentSource] = []
    private var lastReported: AgentActivityState = .inactive
    private var didReportLimit = false
    private var quietTimer: DispatchWorkItem?
    private var generation = UUID()
    private struct TranscriptVersion: Equatable {
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        init?(_ path: String) {
            var metadata = stat()
            guard Darwin.lstat(path, &metadata) == 0,
                  metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
            inode = UInt64(metadata.st_ino); size = metadata.st_size
            modifiedSeconds = metadata.st_mtimespec.tv_sec
            modifiedNanoseconds = metadata.st_mtimespec.tv_nsec
        }
    }
    private var transcriptVersions: [String: TranscriptVersion] = [:]

    var isRunning: Bool { synchronized { stream != nil } }

    init(tracker: AgentActivityTracker,
         onStateChange: @escaping (AgentActivityState) -> Void,
         onSessionLimitReached: @escaping () -> Void = {},
         onSourcesChanged: @escaping ([AgentSource]) -> Void = { _ in }) {
        self.tracker = tracker
        self.onStateChange = onStateChange
        self.onSessionLimitReached = onSessionLimitReached
        self.onSourcesChanged = onSourcesChanged
        eventQueue.setSpecific(key: queueKey, value: true)
    }

    deinit { stop() }

    private func synchronized<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return body() }
        return eventQueue.sync(execute: body)
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath().path
    }

    func start(sources: [AgentSource] = AgentSource.defaults()) {
        synchronized {
            stopOnQueue()
            self.sources = sources.map {
                AgentSource(id: $0.id, displayName: $0.displayName, path: Self.canonical($0.path),
                            fileSuffixes: $0.fileSuffixes, isCustom: $0.isCustom)
            }
            // Watch an existing ancestor, even for absent transcript directories. Recursive
            // events then discover installation/recreation without polling or panel interaction.
            let roots = Set(self.sources.map { source -> String in
                var parent = URL(fileURLWithPath: source.path).deletingLastPathComponent()
                while !Self.isDirectory(parent.path), parent.path != "/" {
                    parent.deleteLastPathComponent()
                }
                return parent.path
            }).sorted()
            guard !roots.isEmpty else { onSourcesChanged([]); return }
            let callbackContext = CallbackContext(self)
            var context = FSEventStreamContext(version: 0,
                info: Unmanaged.passUnretained(callbackContext).toOpaque(),
                retain: { pointer in
                    guard let pointer else { return nil }
                    _ = Unmanaged<CallbackContext>.fromOpaque(pointer).retain()
                    return pointer
                },
                release: { pointer in
                    guard let pointer else { return }
                    Unmanaged<CallbackContext>.fromOpaque(pointer).release()
                }, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
                guard let info,
                      let monitor = Unmanaged<CallbackContext>.fromOpaque(info).takeUnretainedValue().monitor,
                      let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] else { return }
                monitor.handleEvents(paths: array, flags: flags, count: Int(count))
            }
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
            guard let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
                roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else {
                onSourcesChanged([]); return
            }
            FSEventStreamSetDispatchQueue(created, eventQueue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created); FSEventStreamRelease(created)
                onSourcesChanged([]); return
            }
            stream = created
            refreshSources()
        }
    }

    func stop() { synchronized { stopOnQueue() } }

    private func stopOnQueue() {
        generation = UUID()
        quietTimer?.cancel(); quietTimer = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        sources = []; availableSources = []
        transcriptVersions.removeAll()
        lastReported = .inactive; didReportLimit = false
        tracker.reset()
    }

    private static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    private func refreshSources() {
        let updated = sources.filter { Self.isDirectory($0.path) }
        guard updated != availableSources else { return }
        availableSources = updated
        onSourcesChanged(updated)
    }

    private func handleEvents(paths: [String], flags: UnsafePointer<FSEventStreamEventFlags>, count: Int) {
        guard stream != nil else { return }
        refreshSources()
        var matched = false
        for (index, path) in paths.prefix(count).enumerated() {
            let flag = flags[index]
            let writes = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemCloned | kFSEventStreamEventFlagItemRenamed)
            guard flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) == 0,
                  flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0,
                  flag & writes != 0 else { continue }
            // FSEvents paths already use filesystem paths. Reject unrelated parent-watch
            // traffic before any per-file canonicalization or existence checks.
            let lexicalPath = URL(fileURLWithPath: path).standardizedFileURL.path
            guard availableSources.contains(where: { lexicalPath.hasPrefix($0.path == "/" ? "/" : $0.path + "/") }) else { continue }
            let canonical = Self.canonical(path)
            guard let source = availableSources.first(where: { $0.matches(filePath: canonical) }),
                  let version = TranscriptVersion(canonical),
                  transcriptVersions[canonical] != version else { continue }
            // FSEvents may retain/coalesce write bits into a later metadata-only event. File
            // identity, length and nanosecond mtime distinguish it without reading contents.
            if transcriptVersions.count >= 16_384 { transcriptVersions.removeAll(keepingCapacity: true) }
            transcriptVersions[canonical] = version
            tracker.recordActivity(sourceID: source.id)
            matched = true
        }
        guard matched else { return }
        scheduleQuietEvaluation()
        reportCurrentState(activity: true)
    }

    private func scheduleQuietEvaluation() {
        scheduleEvaluation(after: tracker.currentPolicy.activityWindow + 0.02)
    }

    private func scheduleEvaluation(after delay: TimeInterval) {
        quietTimer?.cancel()
        let currentGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == currentGeneration, self.stream != nil else { return }
            self.reportCurrentState()
            if case .grace = self.tracker.evaluate() {
                self.scheduleEvaluation(after: self.tracker.currentPolicy.gracePeriod + 0.02)
            }
        }
        quietTimer = work
        eventQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func reportCurrentState(activity: Bool = false) {
        if tracker.autoSessionExceeded(), !didReportLimit {
            didReportLimit = true
            onSessionLimitReached()
            // Keep the quiet timer: inactivity must eventually clear manager suppression.
        }
        let state = tracker.evaluate()
        if case .inactive = state { didReportLimit = false }
        guard activity || state.displayEquivalent != lastReported.displayEquivalent else { return }
        lastReported = state
        onStateChange(state)
    }
}
