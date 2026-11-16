import Foundation

public struct L10n {
    public let isZh: Bool

    public init(language: AppLanguage, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.isZh = language.resolvedIsChinese(preferredLanguages: preferredLanguages)
    }

    public var appName: String { isZh ? "惜眠" : "SleepSkip" }
    public var idleBadge: String { isZh ? "待机" : "Idle" }
    public var runningBadge: String { isZh ? "运行中" : "Active" }
    public var backpackBadge: String { isZh ? "合盖运行中" : "Lid-Closed" }

    public var notRunningTitle: String { isZh ? "空闲待命" : "Idle" }
    public var idleAutoFollowTitle: String { isZh ? "待命 · 自动跟随 AI Agent" : "Ready · Auto-following AI agents" }
    public var runningTitle: String { isZh ? "正在保持唤醒" : "Keeping Awake" }
    public var indefiniteRunning: String { isZh ? "持续运行" : "Indefinite" }

    public var modeSectionTitle: String { isZh ? "运行模式" : "Mode" }
    public var durationSectionTitle: String { isZh ? "持续时间" : "Duration" }

    public func modeTitle(_ mode: GuardMode) -> String {
        switch mode {
        case .background: return isZh ? "后台运行" : "Background"
        case .keepDisplay: return isZh ? "屏幕常亮" : "Keep Display On"
        }
    }

    public func modeSubtitle(_ mode: GuardMode) -> String {
        switch mode {
        case .background:
            return isZh ? "防止空闲休眠，允许息屏（Codex CLI / 编译）" : "Prevent idle sleep, allow display off"
        case .keepDisplay:
            return isZh ? "防止休眠和息屏（Computer Use / 演示）" : "Keep system and display awake"
        }
    }

    public var modeRecommendedBadge: String { isZh ? "省电推荐" : "Battery Saver" }
    public var modeTipBackground: String { isZh ? "续航最优" : "Best battery" }
    public var modeTipDisplay: String { isZh ? "建议调暗亮度" : "Lower brightness to save power" }

    public var lockOnStartLabel: String { isZh ? "启动即锁屏" : "Lock on start" }
    public var closedLidLabel: String { isZh ? "合盖继续运行（实验性）" : "Lid-closed (experimental)" }
    public var closedLidWarning: String {
        isZh
            ? "需在本机验证恢复行为 · 运行时保持通风"
            : "Verify recovery on this Mac · Keep ventilation clear"
    }

    public var lidModeSectionTitle: String {
        isZh ? "合盖保持方式" : "Lid-closed method"
    }
    public var lidModeStandard: String {
        isZh ? "标准（无需授权）" : "Standard (no auth)"
    }
    public var lidModeStandardDetail: String {
        isZh
            ? "开箱即用。已知限制：合盖状态下插回电源后，约 6–9 秒会进入睡眠。"
            : "Works out of the box. Known limit: plugging the cable back in while the lid is shut sleeps the Mac after 6–9 s."
    }
    public var lidModePrivileged: String {
        isZh ? "兼容（需管理员授权）" : "Compatibility (admin auth)"
    }
    public var lidModePrivilegedDetail: String {
        isZh
            ? "每次启动需授权一次。用于跨电源切换保持，停止后的恢复需在本机验证。"
            : "One authorization per start. Intended for power-source changes; verify sleep recovery on this Mac."
    }
    public var unprivilegedLidUnavailable: String {
        isZh
            ? "系统拒绝了无授权的合盖请求，请在偏好设置里改用兼容模式。"
            : "The system rejected the no-auth lid request. Switch to Compatibility mode in Preferences."
    }

    public var customDuration: String { isZh ? "自定义" : "Custom" }
    public var minutesUnit: String { isZh ? "分钟" : "min" }
    public var applyButton: String { isZh ? "应用" : "Apply" }
    public var startButton: String { isZh ? "开始保持唤醒 (⏎)" : "Start Keeping Awake (⏎)" }
    public var stopButton: String { isZh ? "停止" : "Stop" }
    public var extend30mButton: String { isZh ? "+ 延长 30 分钟" : "+30 min" }
    public var lockScreenButton: String { isZh ? "锁定屏幕" : "Lock Screen" }
    public var quitButton: String { isZh ? "退出应用" : "Quit" }

    public func currentSettingLabel(_ text: String) -> String {
        isZh ? "本次设置：\(text)" : "Duration: \(text)"
    }

    public func projectedEndLabel(_ time: String) -> String {
        isZh ? "预计 \(time) 结束" : "Ends around \(time)"
    }

    public func cliGuardingBanner(_ cli: ExternalCLISession) -> String {
        isZh
            ? "CLI 守护中：\(cli.commandName) (PID \(cli.pid))"
            : "CLI Guarding: \(cli.commandName) (PID \(cli.pid))"
    }

    public func lastConfigSummary(_ config: SessionConfig) -> String {
        let modeTxt = isZh
            ? (config.mode == .background ? "后台" : "常亮")
            : (config.mode == .background ? "Background" : "Display On")
        let lockTxt = config.effectiveLockOnStart ? (isZh ? "+锁屏" : "+Lock") : ""
        let lidTxt = config.effectiveAllowClosedLid ? (isZh ? "+合盖" : "+Lid") : ""
        let durTxt = DurationFormatter.formatDuration(config.durationMinutes, isChinese: isZh)
        return isZh
            ? "上次配置：\(modeTxt)\(lockTxt)\(lidTxt) · \(durTxt)（按 ⏎ 直启）"
            : "Last: \(modeTxt)\(lockTxt)\(lidTxt) · \(durTxt) (Press ⏎)"
    }

    public var staleSleepDisabledBanner: String {
        isZh ? "检测到系统合盖休眠处于禁用状态" : "System lid-close sleep is currently disabled"
    }
    public var restoreSleepButton: String { isZh ? "立即恢复" : "Restore" }

    public func lowBatteryBlockedError(current: Int, threshold: Int) -> String {
        isZh
            ? "当前电量 \(current)% 已低于保护阈值 \(threshold)%，请连接电源或调整阈值"
            : "Battery is at \(current)% (cutoff \(threshold)%); connect power or adjust threshold"
    }

    public var unpluggedBlockedError: String {
        isZh
            ? "已开启「拔电时自动停止」，当前正在使用电池"
            : "Currently on battery while Stop on Unplug is enabled"
    }

    public var overheatedBlockedError: String {
        isZh
            ? "当前机身温度过高，已触发过热保护，暂不启动防休眠"
            : "Mac is running too hot; Thermal Protection prevented starting"
    }

    public var authorizationTimedOut: String {
        isZh ? "授权超时，请重试（若系统已禁用合盖休眠，可点「立即恢复」）" : "Authorization timed out. Try again — or use Restore if lid-close sleep is still disabled."
    }

    public func invalidDurationError(_ maxMinutes: Double) -> String {
        let maxDays = Int(maxMinutes / 60 / 24)
        return isZh
            ? "请输入 1 分钟到 \(maxDays) 天之间的有效时长"
            : "Enter a valid duration between 1 minute and \(maxDays) days"
    }

    // Settings
    public var settingsTitle: String { isZh ? "偏好设置" : "Preferences" }
    public var backButton: String { isZh ? "返回" : "Done" }
    public var launchAtLoginLabel: String { isZh ? "登录时自动启动" : "Launch at Login" }
    public var stopOnUnplugLabel: String { isZh ? "拔掉电源时自动停止" : "Stop when unplugged" }
    public var batteryCutoffLabel: String { isZh ? "低电量自动停止" : "Low-Battery Cutoff" }
    public var batteryCutoffOff: String { isZh ? "关闭" : "Off" }
    public var thermalCutoffLabel: String { isZh ? "过热保护自动停止" : "Thermal Cutoff" }
    public func thermalCutoffName(_ level: ThermalCutoff) -> String {
        switch level {
        case .off: return isZh ? "关闭" : "Off"
        case .serious: return isZh ? "偏高即停" : "Serious"
        case .critical: return isZh ? "过热即停" : "Critical"
        }
    }
    public var cliInstallSectionLabel: String { isZh ? "命令行工具 (sleepskip)" : "CLI Companion (sleepskip)" }
    public var cliInstallButton: String { isZh ? "一键安装" : "Install CLI" }
    public var cliInstalledBadge: String { isZh ? "已安装" : "Installed" }
    public var cliUnavailableLabel: String { isZh ? "需在 .app 中安装" : "Requires .app bundle" }
    public var historySectionTitle: String { isZh ? "最近守护记录" : "Recent Sessions" }
    public var historyEmptyLabel: String { isZh ? "暂无已完成的守护记录" : "No completed sessions yet" }
    public var historyClearButton: String { isZh ? "清空" : "Clear" }
    public func historyEntrySummary(_ entry: SessionHistoryEntry) -> String {
        let start = DurationFormatter.formatClockTime(entry.startedAt)
        let mins = max(1, Int((entry.endedAt.timeIntervalSince(entry.startedAt) / 60.0).rounded()))
        let durText = DurationFormatter.formatDuration(Double(mins), isChinese: isZh)
        let source: String = {
            switch entry.trigger {
            case .autoFollow:
                let names = autoFollowAgentsLabel(entry.agents)
                return names.isEmpty ? autoFollowBadge : names
            case .url:
                return "URL"
            case .manual:
                return entry.closedLid ? backpackBadge : modeTitle(entry.mode)
            }
        }()
        let reason: String = {
            if entry.stopReasonCode.hasPrefix("lowBattery:") {
                let pct = entry.stopReasonCode.split(separator: ":").last ?? ""
                return isZh ? "低电量(\(pct)%)" : "Low battery(\(pct)%)"
            }
            switch entry.stopReasonCode {
            case "manual": return isZh ? "手动停止" : "Manual stop"
            case "expired": return isZh ? "定时到期" : "Expired"
            case "unplugged": return isZh ? "拔电停止" : "Unplugged"
            case "overheated": return isZh ? "过热保护" : "Thermal cutoff"
            case "autoFollowQuiet": return isZh ? "静默释放" : "Idle release"
            case "autoFollowLimit": return isZh ? "达 2h 上限" : "2h limit"
            case "hookStop": return isZh ? "Hook 释放" : "Hook stop"
            default: return isZh ? "已结束" : "Ended"
            }
        }()
        return "\(start) · \(source) · \(durText) · \(reason)"
    }
    public var languageLabel: String { isZh ? "界面语言" : "Language" }
    public var languageSystem: String { isZh ? "跟随系统" : "System" }
    public var globalShortcutLabel: String { isZh ? "全局开关快捷键 (⌃⌥S)" : "Global Shortcut (⌃⌥S)" }
    public var agentSourcesToggleTitle: String { isZh ? "启用的 Agent" : "Enabled agents" }
    public var configureAgentSourcesButton: String { isZh ? "配置来源与自定义目录" : "Configure sources & folders" }
    public var customFoldersLabel: String { isZh ? "自定义监听目录" : "Custom folders" }
    public var addFolderButton: String { isZh ? "添加目录" : "Add Folder" }
    public var claudeHookSectionLabel: String { isZh ? "Claude Code 精准 Hook" : "Claude Code Hook" }
    public var claudeHookConnectButton: String { isZh ? "一键连接" : "Connect" }
    public var claudeHookDisconnectButton: String { isZh ? "已连接 · 断开" : "Connected · Remove" }
    public var claudeHookHint: String {
        isZh
            ? "自动读写 ~/.claude/settings.json，提问即防睡、回复完毕即刻释放。"
            : "Updates ~/.claude/settings.json for instant hold & release."
    }
    public var advancedSettingsTitle: String { isZh ? "高级（电源、合盖与记录）" : "Advanced (Power, Lid & History)" }
    public var safetyFooterHint: String { isZh ? "电量与温控策略见高级设置 · 截止仅释放防休眠" : "Power settings apply to wake protection, not the workload" }

    // Menu bar context menu
    public var menuOpenPanel: String { isZh ? "打开防休眠面板" : "Open Panel" }
    public var menuQuickStart: String { isZh ? "按上次配置快速开启" : "Quick Start (Last Config)" }
    public var menuStop: String { isZh ? "停止保持唤醒" : "Stop Keeping Awake" }

    // Notifications (delivered only on asynchronous background transitions)
    public var notifStoppedTitle: String { isZh ? "防休眠已自动停止" : "SleepSkip Stopped" }
    public var notifExpiredBody: String { isZh ? "预设时长已到期，系统已恢复正常休眠" : "Timer expired; normal sleep restored" }
    public var notifLowBatteryTitle: String { isZh ? "低电量自动保护" : "Low Battery Cutoff" }
    public func notifLowBatteryBody(_ pct: Int) -> String {
        isZh
            ? "电池电量已降至 \(pct)%，已自动停止防休眠并恢复系统休眠"
            : "Battery reached \(pct)%; SleepSkip stopped to protect battery"
    }
    public var notifUnpluggedTitle: String { isZh ? "电源已断开" : "Power Disconnected" }
    public var notifUnpluggedBody: String {
        isZh
            ? "检测到切换至电池供电，已自动停止防休眠"
            : "Switched to battery power; SleepSkip stopped automatically"
    }
    public var notifOverheatedTitle: String { isZh ? "过热自动保护" : "Thermal Protection" }
    public var notifOverheatedBody: String {
        isZh
            ? "温度达到阈值，已释放防休眠；任务仍可能运行，请检查散热"
            : "Thermal threshold reached; wake protection was released. Your task may still be running. Check ventilation."
    }

    // Auto-follow
    public var autoFollowLabel: String { isZh ? "自动跟随 AI Agent" : "Follow AI Agents" }
    public var autoFollowDetail: String {
        isZh
            ? "检测到已启用 Agent 或自定义目录有文件写入时自动保持唤醒，停笔后自动释放。只监听变化，不读取内容，不上传任何数据。"
            : "Hold sleep off while enabled AI agents or custom folders receive writes, then release cleanly. Only file changes are observed — contents are never read."
    }
    public var autoFollowWatching: String { isZh ? "监听目录" : "Watching" }
    public var autoFollowNoticeTitle: String { isZh ? "已开启自动跟随" : "Auto-follow is on" }
    public var autoFollowNoticeBody: String {
        isZh
            ? "Claude Code / Codex / Gemini CLI / OpenCode / DeepSeek Harness 开始干活时自动保持唤醒，停下后自动释放。只监听目录文件是否变化，不读取内容。可在偏好设置里调整或关闭。"
            : "SleepSkip keeps your Mac awake while Claude Code, Codex, Gemini CLI, OpenCode or DeepSeek Harness work, then releases on its own. Only file changes are observed — customize or turn it off in Preferences."
    }
    public var autoFollowUnavailable: String {
        isZh ? "未检测到支持的 Agent 目录" : "No supported agent directory found"
    }
    public var autoFollowBadge: String { isZh ? "跟随中" : "Following" }
    public var autoFollowStandbyBadge: String { isZh ? "自动跟随待命" : "Auto-Follow On" }
    public var autoFollowActiveTitle: String { isZh ? "Agent 运行中，正在保持唤醒" : "Keeping Awake for Agent" }
    public var autoFollowGraceTitle: String { isZh ? "Agent 已停笔，即将自动释放" : "Agent Quiet · Releasing Soon" }
    public func autoFollowCeilingLabel(_ time: String) -> String {
        isZh
            ? "停笔 5 分钟后自动释放 · 上限 \(time)"
            : "Releases 5m after quiet · 2h cap at \(time)"
    }
    public func autoFollowGraceDetail(_ ceilingTime: String) -> String {
        isZh
            ? "若无新写入将自动恢复休眠 · 上限 \(ceilingTime)"
            : "Restores sleep if idle · 2h cap at \(ceilingTime)"
    }
    public var autoFollowPolicySummary: String {
        isZh ? "停笔 5 分钟自动释放 · 单次上限 2 小时" : "5m idle release · 2h max"
    }
    public func autoFollowAgentsLabel(_ agents: [String]) -> String {
        let names = agents.map { name in
            switch name {
            case "claude-code": return "Claude Code"
            case "codex": return "Codex"
            case "dsh": return "DeepSeek Harness"
            case "gemini-cli": return "Gemini CLI"
            case "opencode": return "OpenCode"
            default:
                if name.hasPrefix("custom:") {
                    let path = String(name.dropFirst("custom:".count))
                    let last = URL(fileURLWithPath: path).lastPathComponent
                    return last.isEmpty ? path : last
                }
                return name
            }
        }
        return names.joined(separator: " · ")
    }
    public var autoFollowStopButton: String { isZh ? "停止本次跟随" : "Stop Following" }
    public var autoFollowLimitNotice: String {
        isZh ? "已达单次自动会话上限，已恢复休眠" : "Auto-follow hit its session limit; sleep restored"
    }
    public var notifAutoFollowLimitTitle: String { isZh ? "自动跟随已到上限" : "Auto-Follow Limit Reached" }
    public var notifAutoFollowLimitBody: String {
        isZh
            ? "自动跟随已连续运行 2 小时，已自动释放唤醒断言"
            : "Auto-follow ran for 2 hours; the wake assertion was released"
    }
}
