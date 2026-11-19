import Foundation

public final class PreferencesStore {
    private enum Keys {
        static let mode = "sleepskip.mode"
        static let durationMinutes = "sleepskip.durationMinutes"
        static let customMinutes = "sleepskip.customMinutes"
        static let lockOnStart = "sleepskip.lockOnStart"
        static let allowClosedLid = "sleepskip.allowClosedLid"
        static let closedLidStrategy = "sleepskip.closedLidStrategy"
        static let batteryThreshold = "sleepskip.batteryThresholdPercent"
        static let stopOnUnplug = "sleepskip.stopOnUnplug"
        static let thermalCutoff = "sleepskip.thermalCutoff"
        static let autoFollowAgents = "sleepskip.autoFollowAgents"
        static let autoFollowMaxMinutes = "sleepskip.autoFollowMaxMinutes"
        static let handoffToAutoFollowOnExpiry = "sleepskip.handoffToAutoFollowOnExpiry"
        static let disabledAgentSources = "sleepskip.disabledAgentSources"
        static let customAgentPaths = "sleepskip.customAgentPaths"
        static let globalShortcutEnabled = "sleepskip.globalShortcutEnabled"
        static let language = "sleepskip.language"
        static let history = "sleepskip.history"
        static let hasShownOnboarding = "sleepskip.hasShownOnboarding"
        static let hasSeenAutoFollowNotice = "sleepskip.hasSeenAutoFollowNotice"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = UserDefaults(suiteName: "io.github.laiyongqiang.SleepSkip") ?? .standard) {
        self.defaults = defaults
    }

    public var hasShownOnboarding: Bool {
        get { defaults.bool(forKey: Keys.hasShownOnboarding) }
        set { defaults.set(newValue, forKey: Keys.hasShownOnboarding) }
    }

    public var hasSeenAutoFollowNotice: Bool {
        get { defaults.bool(forKey: Keys.hasSeenAutoFollowNotice) }
        set { defaults.set(newValue, forKey: Keys.hasSeenAutoFollowNotice) }
    }

    public func load() -> SessionConfig {
        let modeRaw = defaults.string(forKey: Keys.mode) ?? GuardMode.background.rawValue
        let mode = GuardMode(rawValue: modeRaw) ?? .background

        let durationMinutes: Double
        if let stored = defaults.object(forKey: Keys.durationMinutes) as? Double {
            // 0 means "indefinite"; anything non-finite or negative falls back to the default.
            durationMinutes = stored == 0 ? 0 : (CommandBuilder.sanitizeMinutes(stored) ?? 240)
        } else {
            durationMinutes = 240
        }

        let customMinutes: Double
        if let stored = defaults.object(forKey: Keys.customMinutes) as? Double {
            customMinutes = CommandBuilder.sanitizeMinutes(stored) ?? 90
        } else {
            customMinutes = 90
        }

        let lockOnStart: Bool
        if defaults.object(forKey: Keys.lockOnStart) != nil {
            lockOnStart = defaults.bool(forKey: Keys.lockOnStart)
        } else {
            lockOnStart = false
        }

        let allowClosedLid: Bool
        if defaults.object(forKey: Keys.allowClosedLid) != nil {
            allowClosedLid = defaults.bool(forKey: Keys.allowClosedLid)
        } else {
            allowClosedLid = false
        }

        // Defaults to the no-authorization path: the app should work out of the box. Anyone
        // who needs the power-change guarantee can switch to the privileged path in Preferences.
        let closedLidStrategy: ClosedLidStrategy
        if let raw = defaults.string(forKey: Keys.closedLidStrategy),
           let parsed = ClosedLidStrategy(rawValue: raw) {
            closedLidStrategy = parsed
        } else {
            closedLidStrategy = .unprivileged
        }

        let batteryThreshold: Int
        if defaults.object(forKey: Keys.batteryThreshold) != nil {
            batteryThreshold = max(0, defaults.integer(forKey: Keys.batteryThreshold))
        } else {
            batteryThreshold = 10
        }

        let stopOnUnplug: Bool
        if defaults.object(forKey: Keys.stopOnUnplug) != nil {
            stopOnUnplug = defaults.bool(forKey: Keys.stopOnUnplug)
        } else {
            stopOnUnplug = false
        }

        let thermalCutoff: ThermalCutoff
        if let raw = defaults.string(forKey: Keys.thermalCutoff),
           let parsed = ThermalCutoff(rawValue: raw) {
            thermalCutoff = parsed
        } else {
            thermalCutoff = .critical
        }

        // On by default: the product promise is that the app works without being configured.
        // Anyone who has ever flipped the switch has a stored value and keeps their choice.
        let autoFollowAgents: Bool
        if defaults.object(forKey: Keys.autoFollowAgents) != nil {
            autoFollowAgents = defaults.bool(forKey: Keys.autoFollowAgents)
        } else {
            autoFollowAgents = true
        }

        let autoFollowMaxMinutes: Double
        if let stored = defaults.object(forKey: Keys.autoFollowMaxMinutes) as? Double {
            autoFollowMaxMinutes = stored == 0 ? 0 : (CommandBuilder.sanitizeMinutes(stored) ?? 120)
        } else {
            autoFollowMaxMinutes = 120
        }

        let handoffToAutoFollowOnExpiry: Bool
        if defaults.object(forKey: Keys.handoffToAutoFollowOnExpiry) != nil {
            handoffToAutoFollowOnExpiry = defaults.bool(forKey: Keys.handoffToAutoFollowOnExpiry)
        } else {
            handoffToAutoFollowOnExpiry = true
        }

        let disabledAgentSources = defaults.stringArray(forKey: Keys.disabledAgentSources) ?? []
        let customAgentPaths = defaults.stringArray(forKey: Keys.customAgentPaths) ?? []

        let globalShortcutEnabled: Bool
        if defaults.object(forKey: Keys.globalShortcutEnabled) != nil {
            globalShortcutEnabled = defaults.bool(forKey: Keys.globalShortcutEnabled)
        } else {
            globalShortcutEnabled = true
        }

        let langRaw = defaults.string(forKey: Keys.language) ?? AppLanguage.system.rawValue
        let language = AppLanguage(rawValue: langRaw) ?? .system

        return SessionConfig(
            mode: mode,
            durationMinutes: durationMinutes,
            customMinutes: customMinutes,
            lockOnStart: lockOnStart,
            allowClosedLid: allowClosedLid,
            closedLidStrategy: closedLidStrategy,
            batteryThresholdPercent: batteryThreshold,
            stopOnUnplug: stopOnUnplug,
            thermalCutoff: thermalCutoff,
            autoFollowAgents: autoFollowAgents,
            autoFollowMaxMinutes: autoFollowMaxMinutes,
            handoffToAutoFollowOnExpiry: handoffToAutoFollowOnExpiry,
            disabledAgentSourceIDs: disabledAgentSources,
            customAgentPaths: customAgentPaths,
            globalShortcutEnabled: globalShortcutEnabled,
            language: language
        )
    }

    public func save(_ config: SessionConfig) {
        defaults.set(config.mode.rawValue, forKey: Keys.mode)
        defaults.set(config.durationMinutes, forKey: Keys.durationMinutes)
        defaults.set(config.customMinutes, forKey: Keys.customMinutes)
        defaults.set(config.lockOnStart, forKey: Keys.lockOnStart)
        defaults.set(config.allowClosedLid, forKey: Keys.allowClosedLid)
        defaults.set(config.closedLidStrategy.rawValue, forKey: Keys.closedLidStrategy)
        defaults.set(config.batteryThresholdPercent, forKey: Keys.batteryThreshold)
        defaults.set(config.stopOnUnplug, forKey: Keys.stopOnUnplug)
        defaults.set(config.thermalCutoff.rawValue, forKey: Keys.thermalCutoff)
        defaults.set(config.autoFollowAgents, forKey: Keys.autoFollowAgents)
        defaults.set(config.autoFollowMaxMinutes, forKey: Keys.autoFollowMaxMinutes)
        defaults.set(config.handoffToAutoFollowOnExpiry, forKey: Keys.handoffToAutoFollowOnExpiry)
        defaults.set(config.disabledAgentSourceIDs, forKey: Keys.disabledAgentSources)
        defaults.set(config.customAgentPaths, forKey: Keys.customAgentPaths)
        defaults.set(config.globalShortcutEnabled, forKey: Keys.globalShortcutEnabled)
        defaults.set(config.language.rawValue, forKey: Keys.language)
    }

    public func loadHistory() -> [SessionHistoryEntry] {
        guard let data = defaults.data(forKey: Keys.history) else { return [] }
        return (try? JSONDecoder().decode([SessionHistoryEntry].self, from: data)) ?? []
    }

    public func saveHistory(_ entries: [SessionHistoryEntry]) {
        let capped = Array(entries.prefix(10))
        if let data = try? JSONEncoder().encode(capped) {
            defaults.set(data, forKey: Keys.history)
        }
    }
}
