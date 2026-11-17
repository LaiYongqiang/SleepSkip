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
    public var authorizingBadge: String { isZh ? "等待授权" : "Authorizing" }

    public var notRunningTitle: String { isZh ? "空闲待命" : "Idle" }
    public func idleWatchingSourcesSummary(_ count: Int) -> String {
        isZh ? "监听 \(count) 个来源" : "Watching \(count) source\(count == 1 ? "" : "s")"
    }
    public var idleHookReadySummary: String {
        isZh ? "Hook 已连接" : "Hook connected"
    }
    public var idleNoSourcesTitle: String {
        isZh ? "待命 · 未找到可用 Agent 目录" : "Standby · No Agent Folders Found"
    }
    public var idleNoSourcesDetail: String {
        isZh
            ? "未检测到已启用的 Agent 目录，可手动启动，或在偏好设置中添加目录 / 连接 Hook。"
            : "No enabled agent folders found. Start manually below, or add folders / connect Hook in Preferences."
    }
    public var configureSourcesAction: String {
        isZh ? "配置来源与 Hook" : "Configure Sources & Hook"
    }

    public var autoFollowPausedTitle: String {
        isZh ? "本次跟随已暂停" : "Following Paused"
    }
    public var autoFollowLimitTitle: String {
        isZh ? "已达 2 小时上限，自动跟随已暂停" : "Auto-Follow Paused · 2h Limit"
    }
    public func autoFollowPausedDetail(sourceKind: AutoFollowSourceKind, limitReached: Bool) -> String {
        if limitReached {
            switch sourceKind {
            case .hookOnly:
                return isZh
                    ? "已释放唤醒保护；当前 Hook 会话结束并开启新任务后自动恢复，也可立即恢复。"
                    : "Wake protection released; resumes when this hook ends and a new task starts, or resume now."
            case .directoryOnly, .none:
                return isZh
                    ? "已释放唤醒保护；目录静默约 5 分钟并在下一轮活动时自动恢复，也可立即恢复。"
                    : "Wake protection released; resumes on new activity after ~5m quiet, or resume now."
            case .both:
                return isZh
                    ? "已释放唤醒保护；Hook 结束且目录静默约 5 分钟后自动恢复，也可立即恢复。"
                    : "Wake protection released; resumes after hook stop and ~5m quiet, or resume now."
            }
        } else {
            switch sourceKind {
            case .hookOnly:
                return isZh
                    ? "已手动停止本轮保持；当前 Hook 会话结束后新会话将重新触发，也可立即恢复。"
                    : "Stopped manually; resumes when a new hook session starts after this one ends, or resume now."
            case .directoryOnly, .none:
                return isZh
                    ? "已手动停止本轮保持；目录静默约 5 分钟后下一轮写入时自动恢复，也可立即恢复。"
                    : "Stopped manually; resumes on the next write after ~5m of quiet, or resume now."
            case .both:
                return isZh
                    ? "已手动停止本轮保持；当前 Hook 结束且目录静默后自动恢复，也可立即恢复。"
                    : "Stopped manually; resumes after active hooks end and folders go quiet, or resume now."
            }
        }
    }
    public var resumeAutoFollowButton: String { isZh ? "立即恢复跟随" : "Resume Following" }

    public var authorizingTitle: String {
        isZh ? "等待管理员授权" : "Waiting for Administrator Authorization"
    }
    public func authorizingDetail(_ summary: String) -> String {
        isZh
            ? "请在系统提示框中确认以启用兼容合盖模式。本次请求：\(summary)"
            : "Approve the system prompt for compatibility lid mode. Pending: \(summary)"
    }
    public var cancelLaunchButton: String { isZh ? "取消本次启动" : "Cancel Launch" }

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
    public var durationFollowStateHint: String { isZh ? "转为手动后生效" : "Applies after switching to manual" }

    public var lockOnStartLabel: String { isZh ? "启动即锁屏" : "Lock on start" }
    public var closedLidLabel: String { isZh ? "合盖继续运行" : "Lid-closed" }
    public func closedLidInlineNote(strategy: ClosedLidStrategy) -> String {
        switch strategy {
        case .unprivileged:
            return isZh
                ? "实验性 · 合盖后插回电源约 6–9 秒会睡眠，详情见偏好设置"
                : "Experimental · Sleeps ~6–9 s after plugging power back in while closed; see Preferences"
        case .privileged:
            return isZh
                ? "实验性 · 每次启动需管理员授权一次，详情见偏好设置"
                : "Experimental · Needs admin authorization once per start; see Preferences"
        }
    }
    public var changeClosedLidMethodButton: String { isZh ? "切换方式" : "Change method" }

    public var lidModeSectionTitle: String {
        isZh ? "合盖保持方式（实验性）" : "Lid-closed method (experimental)"
    }
    public var lidModeStandard: String {
        isZh ? "标准（无需授权）" : "Standard (no auth)"
    }
    public var lidModeStandardDetail: String {
        isZh
            ? "开箱即用。已知限制：合盖状态下插回电源后，约 6–9 秒会进入睡眠。"
            : "Works out of the box. Known limit: plugging power back in while closed sleeps the Mac after 6–9 s."
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

    public func startButtonTitle(for config: SessionConfig, isFollowingAgents: Bool = false) -> String {
        let needsAuth = config.effectiveAllowClosedLid && config.closedLidStrategy == .privileged
        let durationText = DurationFormatter.formatDuration(config.durationMinutes, isChinese: isZh)
        if isFollowingAgents {
            // In following state the primary action promotes the session to manual.
            return needsAuth
                ? (isZh ? "授权转手动 · \(durationText)" : "Authorize & Switch · \(durationText)")
                : (isZh ? "转为手动 · \(durationText)" : "Switch to Manual · \(durationText)")
        }
        if needsAuth {
            return isZh ? "授权并开始保持唤醒" : "Authorize & Start"
        }
        return isZh ? "开始保持唤醒" : "Start Keeping Awake"
    }

    public var stopButton: String { isZh ? "停止保持唤醒" : "Stop Keeping Awake" }
    public var extend30mButton: String { isZh ? "+ 延长 30 分钟" : "+30 min" }
    public var lockScreenButton: String { isZh ? "锁定屏幕" : "Lock Screen" }
    public var quitButton: String { isZh ? "退出应用" : "Quit" }

    public func currentSettingLabel(_ text: String) -> String {
        isZh ? "手动计时：\(text)" : "Manual timer: \(text)"
    }

    public func projectedEndLabel(_ time: String) -> String {
        isZh ? "预计 \(time) 结束" : "Ends around \(time)"
    }

    public func cliGuardingBanner(_ cli: ExternalCLISession) -> String {
        isZh
            ? "外部 CLI 守护中：\(cli.commandName) (PID \(cli.pid))"
            : "External CLI Guarding: \(cli.commandName) (PID \(cli.pid))"
    }
    public var cliGuardingDetail: String {
        isZh
            ? "由终端命令独立保持唤醒；在本面板停止或退出应用不会结束该 CLI 任务，请在终端内中止。"
            : "Held independently by that CLI process. Stopping or quitting this app will not end the command."
    }

    public func launchConfigSummary(_ config: SessionConfig) -> String {
        let summary = compactConfigDescription(
            mode: config.mode,
            durationMinutes: config.durationMinutes,
            lockOnStart: config.effectiveLockOnStart,
            closedLid: config.effectiveAllowClosedLid
        )
        return isZh
            ? "当前启动配置：\(summary)（按 ⏎ 启动）"
            : "Launch config: \(summary) (Press ⏎)"
    }

    public func compactConfigDescription(
        mode: GuardMode,
        durationMinutes: Double,
        lockOnStart: Bool,
        closedLid: Bool
    ) -> String {
        let modeTxt = isZh
            ? (mode == .background ? "后台" : "常亮")
            : (mode == .background ? "Background" : "Display On")
        let lockTxt = (mode == .background && lockOnStart) ? (isZh ? "+锁屏" : "+Lock") : ""
        let lidTxt = (mode == .background && closedLid) ? (isZh ? "+合盖" : "+Lid") : ""
        let durTxt = DurationFormatter.formatDuration(durationMinutes, isChinese: isZh)
        return "\(modeTxt)\(lockTxt)\(lidTxt) · \(durTxt)"
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
    public var backButton: String { isZh ? "完成" : "Done" }
    public var generalSectionTitle: String { isZh ? "通用" : "General" }
    public var powerAndLidSectionTitle: String { isZh ? "电源、温控与合盖" : "Power, Thermal & Lid" }
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
    public var thermalCutoffHint: String {
        isZh
            ? "达到温度阈值时仅释放本应用的防休眠保护，不会终止运行中的任务。"
            : "Releases wake protection when hot; running tasks are not stopped."
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
            case "manualPromotion": return isZh ? "转为手动" : "To manual"
            case "expired": return isZh ? "定时到期" : "Expired"
            case "unplugged": return isZh ? "拔电停止" : "Unplugged"
            case "overheated": return isZh ? "过热保护" : "Thermal cutoff"
            case "autoFollowQuiet": return isZh ? "静默释放" : "Idle release"
            case "autoFollowLimit": return isZh ? "达 2h 上限" : "2h limit"
            case "hookStop": return isZh ? "Hook 释放" : "Hook stop"
            case "hookLeaseExpired": return isZh ? "Hook 超时" : "Hook cap"
            default: return isZh ? "已结束" : "Ended"
            }
        }()
        return "\(start) · \(source) · \(durText) · \(reason)"
    }
    public var languageLabel: String { isZh ? "界面语言" : "Language" }
    public var languageSystem: String { isZh ? "跟随系统" : "System" }
    public var globalShortcutLabel: String { isZh ? "全局开关快捷键 (⌃⌥S)" : "Global Shortcut (⌃⌥S)" }
    public var configureAgentSourcesButton: String { isZh ? "管理支持的 Agent 与自定义目录" : "Sources & Custom Folders" }
    public var customFoldersLabel: String { isZh ? "自定义监听目录" : "Custom folders" }
    public var addFolderButton: String { isZh ? "添加目录" : "Add Folder" }

    public var claudeHookSectionLabel: String { isZh ? "Claude Code 精准 Hook" : "Claude Code Hook" }
    public var claudeHookIndependentBadge: String { isZh ? "独立运行" : "Independent" }
    public var claudeHookConnectedBadge: String { isZh ? "已连接" : "Connected" }
    public var claudeHookDisconnectedBadge: String { isZh ? "未连接" : "Not Connected" }
    public var claudeHookHoldingBadge: String { isZh ? "保持中" : "Holding" }
    public var claudeHookNotHoldingBadge: String { isZh ? "未保持" : "Not Holding" }
    public func claudeHookStatusBadge(_ status: HookProtectionStatus) -> String? {
        switch status {
        case .none:
            return nil
        case .holding:
            return claudeHookHoldingBadge
        case .paused(let limitReached):
            if limitReached {
                return isZh ? "达上限已暂停" : "Paused (2h Limit)"
            }
            return isZh ? "已暂停" : "Paused"
        case .standbyBehindManual:
            return isZh ? "手动优先" : "Manual Priority"
        case .waitingForAuthorization(let existing):
            switch existing {
            case .none:
                return isZh ? "待授权 · 未保持" : "Auth · Not Holding"
            case .manual:
                return isZh ? "待授权 · 手动保持" : "Auth · Manual Held"
            case .autoFollow:
                return isZh ? "待授权 · 跟随保持" : "Auth · Follow Held"
            }
        }
    }
    public func claudeHookStatusDetail(_ status: HookProtectionStatus) -> String? {
        switch status {
        case .none:
            return nil
        case .holding:
            return isZh
                ? "当前有 Hook 会话正在通过自动跟随保持唤醒。"
                : "An active hook session is currently holding wake protection."
        case .paused(let limitReached):
            if limitReached {
                return isZh
                    ? "检测到进行中的 Hook 会话，因达 2 小时上限已释放唤醒保护。"
                    : "Hook session is still active, but wake protection was released at the 2h limit."
            }
            return isZh
                ? "检测到进行中的 Hook 会话，但本次跟随已暂停（当前未保持唤醒）。"
                : "Hook session is active, but auto-following is paused (not holding wake protection)."
        case .standbyBehindManual:
            return isZh
                ? "检测到进行中的 Hook 会话；当前由手动会话保持唤醒，可主动切回自动跟随；手动停止后需按暂停规则恢复。"
                : "Hook session is active; a manual session currently holds wake protection. You can switch back to auto-follow, while a manual stop pauses following until recovery."
        case .waitingForAuthorization(let existing):
            switch existing {
            case .none:
                return isZh
                    ? "检测到进行中的 Hook 会话；正在等待管理员授权，当前尚未保持唤醒。"
                    : "Hook session is active; waiting for administrator authorization (not holding wake protection yet)."
            case .manual:
                return isZh
                    ? "检测到进行中的 Hook 会话；正在等待替换授权，当前仍由原有手动会话保持唤醒。"
                    : "Hook session is active; waiting for replacement authorization while the existing manual session holds wake protection."
            case .autoFollow:
                return isZh
                    ? "当前 Hook 会话正通过旧的自动跟随保持唤醒，同时正在等待新手动会话的管理员授权。"
                    : "Hook session is holding wake protection via the current auto-follow session while waiting for replacement authorization."
            }
        }
    }
    public var claudeHookConnectButton: String { isZh ? "连接 Hook" : "Connect" }
    public var claudeHookDisconnectButton: String { isZh ? "断开 Hook" : "Disconnect" }
    public var claudeHookHint: String {
        isZh
            ? "独立于目录监听开关。读写 ~/.claude/settings.json，提问时开始保持，回复结束后释放对应来源的保护；其他活动或手动计时仍可能继续保持唤醒。"
            : "Runs independently of folder watching. Updates ~/.claude/settings.json to hold on prompt submit and release this source on stop; other active sources or manual timers may continue holding."
    }

    public var safetyFooterHint: String {
        isZh
            ? "电源/温控截止、停止保护与退出应用仅释放防休眠，不会结束 CLI 或 Agent 任务"
            : "Cutoffs, Stop & Quit release wake protection only — never your CLI or Agent tasks"
    }

    // Menu bar context menu
    public var menuOpenPanel: String { isZh ? "打开防休眠面板" : "Open Panel" }
    public var menuQuickStart: String { isZh ? "按当前配置快速开启" : "Quick Start (Saved Config)" }
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

    // Folder watching / Auto-follow
    public var autoFollowLabel: String { isZh ? "监听 Agent 目录" : "Watch Agent Folders" }
    public var autoFollowDetail: String {
        isZh
            ? "检测到已启用 Agent 或自定义目录有文件写入时自动保持唤醒，停笔后释放。只监听变化，不读取内容，不上传数据。"
            : "Keeps your Mac awake when enabled agent or custom folders receive writes, then releases cleanly. Contents are never read."
    }
    public var autoFollowWatching: String { isZh ? "监听目录" : "Watching" }
    public var autoFollowNoticeTitle: String { isZh ? "已开启 Agent 目录监听" : "Agent Folder Watching is On" }
    public var autoFollowNoticeBody: String {
        isZh
            ? "检测到 Claude Code / Codex / Gemini CLI / OpenCode / DeepSeek Harness 目录有文件写入时自动保持唤醒，停下后释放。仅监听文件变化，不读取内容。可在偏好设置中调整。"
            : "SleepSkip keeps your Mac awake when Claude Code, Codex, Gemini CLI, OpenCode or DeepSeek Harness write to their folders, then releases cleanly. Only file changes are observed."
    }
    public var autoFollowUnavailable: String {
        isZh ? "未检测到已启用的 Agent 目录" : "No enabled agent directory found"
    }
    public var autoFollowBadge: String { isZh ? "自动跟随" : "Auto-Follow" }
    public var autoFollowActiveTitle: String { isZh ? "Agent 运行中，正在保持唤醒" : "Keeping Awake for Agent" }
    public var autoFollowGraceTitle: String { isZh ? "目录已停笔，即将自动释放" : "Agent Quiet · Releasing Soon" }

    public func returnToAutoFollowButton(dropsClosedLid: Bool) -> String {
        if dropsClosedLid {
            return isZh ? "切回自动跟随（将关闭合盖保护）" : "Return to Auto-Follow (disables lid-closed)"
        }
        return isZh ? "切回自动跟随" : "Return to Auto-Follow"
    }
    public var confirmAutoFollowSwitchTitle: String {
        isZh ? "切回自动跟随会关闭合盖保护" : "Switching disables lid-closed protection"
    }
    public var confirmAutoFollowSwitchDetail: String {
        isZh
            ? "切回后将关闭合盖保护，并转为 2 小时上限的自动跟随"
            : "Switching disables lid-closed protection and resumes auto-follow (2h cap)"
    }
    public var confirmAutoFollowSwitchButton: String {
        isZh ? "关闭合盖并切回" : "Disable Lid & Switch"
    }
    public var keepClosedLidSessionButton: String {
        isZh ? "保留合盖会话" : "Keep Lid-Closed"
    }

    public func autoFollowCeilingLabel(_ time: String, sourceKind: AutoFollowSourceKind) -> String {
        switch sourceKind {
        case .hookOnly:
            return isZh
                ? "Hook 结束时释放此来源 · 2 小时上限 \(time)"
                : "Releases on hook stop · 2h cap at \(time)"
        case .directoryOnly, .none:
            return isZh
                ? "停笔 5 分钟后自动释放 · 上限 \(time)"
                : "Releases 5m after quiet · 2h cap at \(time)"
        case .both:
            return isZh
                ? "Hook 结束且目录停笔 5 分钟后释放 · 上限 \(time)"
                : "Releases after hook stop & 5m quiet · 2h cap at \(time)"
        }
    }

    public func autoFollowGraceDetail(_ ceilingTime: String) -> String {
        isZh
            ? "若无新写入将自动恢复休眠 · 上限 \(ceilingTime)"
            : "Restores sleep if idle · 2h cap at \(ceilingTime)"
    }

    public func autoFollowPolicySummary(_ sourceKind: AutoFollowSourceKind) -> String {
        switch sourceKind {
        case .hookOnly:
            return isZh ? "由 Hook 控制起止 · 单次上限 2 小时" : "Hook-controlled release · 2h max"
        case .directoryOnly, .none:
            return isZh ? "停笔 5 分钟自动释放 · 单次上限 2 小时" : "5m idle release · 2h max"
        case .both:
            return isZh ? "Hook 释放 + 目录停笔 5 分钟 · 上限 2 小时" : "Hook stop + 5m folder idle · 2h max"
        }
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
    public var stopSessionClarification: String {
        isZh
            ? "仅停止本应用防休眠，不会中断正在运行的 Agent 或终端任务"
            : "Stops wake protection only; running Agent or CLI tasks continue"
    }
    public var autoFollowLimitNotice: String {
        isZh ? "已达单次自动会话上限，已恢复休眠" : "Auto-follow hit its session limit; sleep restored"
    }
    public var notifAutoFollowLimitTitle: String { isZh ? "自动跟随已到上限" : "Auto-Follow Limit Reached" }
    public var notifAutoFollowLimitBody: String {
        isZh
            ? "自动跟随已连续运行 2 小时，已自动释放唤醒断言"
            : "Auto-follow ran for 2 hours; the wake assertion was released"
    }

    // Accessibility
    public var dismissErrorA11y: String { isZh ? "关闭错误提示" : "Dismiss error" }
    public var dismissNoticeA11y: String { isZh ? "关闭提示" : "Dismiss notice" }
    public func removeFolderA11y(_ path: String) -> String {
        isZh ? "移除目录 \(path)" : "Remove folder \(path)"
    }
    public var selectedA11y: String { isZh ? "已选中" : "Selected" }
    public var notSelectedA11y: String { isZh ? "未选中" : "Not selected" }
    public var enabledA11y: String { isZh ? "已启用" : "Enabled" }
    public var disabledA11y: String { isZh ? "已停用" : "Disabled" }
    public var expandedA11y: String { isZh ? "已展开" : "Expanded" }
    public var collapsedA11y: String { isZh ? "已收起" : "Collapsed" }
    public func activeStatusSummaryA11y(mode: String, remaining: String) -> String {
        isZh ? "当前正在保持唤醒，\(mode)，剩余 \(remaining)" : "Keeping awake, \(mode), remaining \(remaining)"
    }
}
