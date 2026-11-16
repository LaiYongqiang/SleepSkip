import Cocoa
import SleepSkipCore
import SwiftUI

struct SleepSkipPopoverView: View {
    @ObservedObject var manager: SessionManager

    private var t: L10n { manager.l10n }

    var body: some View {
        VStack(spacing: 12) {
            headerBar

            if let error = manager.errorMessage {
                errorBanner(error)
            } else if manager.staleSleepDisabled && !manager.isRunning {
                staleSleepBanner
            }

            if let cli = manager.externalCLI {
                cliBanner(cli)
            }

            if manager.showAutoFollowNotice {
                autoFollowNotice
            }

            if manager.showSettings {
                settingsContent
            } else if manager.isRunning {
                runningContent
            } else {
                idleContent
            }
        }
        .padding(16)
        .frame(width: 356)
        // NSPopover's own background is translucent, so without an opaque fill the desktop and
        // the menu bar behind it show through and the whole panel reads as washed-out grey.
        .background(Color(NSColor.windowBackgroundColor))
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(nsImage: StatusBarIcon.image(active: manager.isEffectivelyActive))
                .renderingMode(.template)
                .foregroundColor(manager.isEffectivelyActive ? .accentColor : .primary)
                .frame(width: 18, height: 18)

            Text(t.appName)
                .font(.system(size: 14, weight: .semibold))

            if manager.isFollowingAgents {
                // Auto-follow reads as a different thing from a session the user started.
                Text(t.autoFollowBadge)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.blue.opacity(0.14)))
            } else if manager.isRunning {
                Text(manager.activeClosedLid ? t.backpackBadge : t.runningBadge)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.green.opacity(0.14)))
            } else if manager.externalCLI != nil {
                Text("CLI")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.blue.opacity(0.14)))
            }

            Spacer()

            Button(action: {
                manager.refreshClaudeHookStatus()
                manager.showSettings.toggle()
            }) {
                Image(systemName: manager.showSettings ? "xmark.circle.fill" : "gearshape")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .help(manager.showSettings ? t.backButton : t.settingsTitle)
        }
    }

    // MARK: - Banners

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.red)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: { manager.errorMessage = nil }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.red.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.red.opacity(0.25), lineWidth: 1)
        )
    }

    /// Shown once, on first launch, because auto-follow is on by default and watches a folder.
    /// Telling the user up front is what makes "works without configuration" honest.
    private var autoFollowNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                Text(t.autoFollowNoticeTitle)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button(action: { manager.dismissAutoFollowNotice() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
            Text(t.autoFollowNoticeBody)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
        )
    }

    private var staleSleepBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.trianglebadge.exclamationmark.fill")
                .font(.system(size: 12))
                .foregroundColor(.orange)
            Text(t.staleSleepDisabledBanner)
                .font(.system(size: 11))
                .foregroundColor(.primary)
            Spacer()
            Button(t.restoreSleepButton) {
                manager.restoreStaleSleepDisabled()
            }
            .buttonStyle(BorderedButtonStyle())
            .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }

    private func cliBanner(_ cli: ExternalCLISession) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.blue)
            Text(t.cliGuardingBanner(cli))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.blue.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.blue.opacity(0.22), lineWidth: 1)
        )
    }

    // MARK: - Idle View

    private var idleContent: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                let autoReady = manager.config.autoFollowAgents && !manager.agentSources.isEmpty
                HStack(spacing: 6) {
                    Circle()
                        .fill(autoReady ? Color.blue.opacity(0.75) : Color.secondary.opacity(0.45))
                        .frame(width: 6, height: 6)
                    Text(autoReady ? t.idleAutoFollowTitle : t.notRunningTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(autoReady ? .primary : .secondary)
                }
                Text(t.lastConfigSummary(manager.config))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
            )

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(t.modeSectionTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(manager.config.mode == .background ? t.modeTipBackground : t.modeTipDisplay)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                VStack(spacing: 0) {
                    modeRow(
                        mode: .background,
                        isSelected: manager.config.mode == .background,
                        badge: t.modeRecommendedBadge
                    ) {
                        manager.selectMode(.background)
                    }

                    if manager.config.mode == .background {
                        Divider()
                            .padding(.horizontal, 10)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 12) {
                                Toggle(t.lockOnStartLabel, isOn: Binding(
                                    get: { manager.config.lockOnStart },
                                    set: { manager.setLockOnStart($0) }
                                ))
                                .toggleStyle(CheckboxToggleStyle())
                                .font(.system(size: 11))

                                Toggle(t.closedLidLabel, isOn: Binding(
                                    get: { manager.config.allowClosedLid },
                                    set: { manager.setAllowClosedLid($0) }
                                ))
                                .toggleStyle(CheckboxToggleStyle())
                                .font(.system(size: 11))
                            }

                            if manager.config.allowClosedLid {
                                Text(t.closedLidWarning)
                                    .font(.system(size: 10))
                                    .foregroundColor(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .background(cardBackground(selected: manager.config.mode == .background))
                .overlay(cardBorder(selected: manager.config.mode == .background))

                modeRow(
                    mode: .keepDisplay,
                    isSelected: manager.config.mode == .keepDisplay,
                    badge: nil
                ) {
                    manager.selectMode(.keepDisplay)
                }
                .background(cardBackground(selected: manager.config.mode == .keepDisplay))
                .overlay(cardBorder(selected: manager.config.mode == .keepDisplay))
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(t.durationSectionTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(DurationFormatter.formatDuration(manager.config.durationMinutes, isChinese: t.isZh))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 5) {
                    ForEach(SessionConfig.standardPresets, id: \.self) { min in
                        durationChip(
                            title: DurationFormatter.formatShortPreset(min, isChinese: t.isZh),
                            selected: manager.config.durationMinutes == min && !manager.showCustomInput
                        ) {
                            manager.selectDuration(min)
                        }
                    }

                    let isCustomSelected = !SessionConfig.standardPresets.contains(manager.config.durationMinutes)
                    let customLabel: String = {
                        guard isCustomSelected else { return t.customDuration }
                        let mins = Int(manager.config.durationMinutes.rounded())
                        return t.isZh ? "\(mins)分" : "\(mins)m"
                    }()
                    durationChip(
                        title: customLabel,
                        selected: isCustomSelected || manager.showCustomInput
                    ) {
                        manager.showCustomInput.toggle()
                    }
                }

                if manager.showCustomInput {
                    HStack(spacing: 6) {
                        Text(t.customDuration)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        TextField("90", text: Binding(
                            get: { manager.customMinutesText },
                            set: { manager.customMinutesText = $0 }
                        ))
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 64)
                        .multilineTextAlignment(.center)
                        .onSubmit {
                            manager.applyCustomDuration()
                        }
                        Text(t.minutesUnit)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(t.applyButton) {
                            manager.applyCustomDuration()
                        }
                        .buttonStyle(BorderedButtonStyle())
                        .controlSize(.small)
                    }
                    .padding(.top, 2)
                }
            }

            Button(action: {
                manager.startConfiguredSession()
            }) {
                HStack(spacing: 6) {
                    if manager.isAuthorizing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11))
                    }
                    Text(t.startButton)
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(manager.isAuthorizing ? 0.65 : 1.0))
                )
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(manager.isAuthorizing)
        }
    }

    // MARK: - Running View

    private var runningContent: some View {
        let isGracePhase = manager.isFollowingAgents && manager.autoFollowGraceEndDate != nil
        let statusAccent: Color = isGracePhase ? .orange : .green
        let statusTitle: String = {
            if manager.isFollowingAgents {
                return isGracePhase ? t.autoFollowGraceTitle : t.autoFollowActiveTitle
            }
            return t.runningTitle
        }()

        return VStack(spacing: 12) {
            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusAccent)
                        .frame(width: 7, height: 7)
                    Text(statusTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(statusAccent)
                }

                if manager.isIndefinite {
                    Text(t.indefiniteRunning)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .padding(.vertical, 2)
                } else {
                    let displaySeconds = isGracePhase ? manager.autoFollowGraceRemainingSeconds : manager.remainingSeconds
                    Text(DurationFormatter.formatCountdown(displaySeconds))
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }

                let modeSummary = t.modeTitle(manager.activeMode)
                let lidPart = manager.activeClosedLid ? " · \(t.backpackBadge)" : ""
                if manager.isFollowingAgents {
                    Text("\(t.autoFollowBadge) · \(t.autoFollowAgentsLabel(manager.followingAgents))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.blue)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("\(modeSummary)\(lidPart)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }

                if let endDate = manager.endDate, !manager.isIndefinite {
                    let detailText: String = {
                        let timeText = DurationFormatter.formatClockTime(endDate)
                        if manager.isFollowingAgents {
                            return isGracePhase ? t.autoFollowGraceDetail(timeText) : t.autoFollowCeilingLabel(timeText)
                        }
                        return t.projectedEndLabel(timeText)
                    }()
                    Text(detailText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(statusAccent.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(statusAccent.opacity(0.22), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(t.modeSectionTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)

                modeRow(
                    mode: .background,
                    isSelected: manager.activeMode == .background,
                    badge: nil
                ) {
                    manager.switchRunningMode(to: .background)
                }
                .background(cardBackground(selected: manager.activeMode == .background))
                .overlay(cardBorder(selected: manager.activeMode == .background))

                modeRow(
                    mode: .keepDisplay,
                    isSelected: manager.activeMode == .keepDisplay,
                    badge: nil
                ) {
                    manager.switchRunningMode(to: .keepDisplay)
                }
                .background(cardBackground(selected: manager.activeMode == .keepDisplay))
                .overlay(cardBorder(selected: manager.activeMode == .keepDisplay))
            }

            if manager.isFollowingAgents {
                HStack {
                    Text(t.autoFollowPolicySummary)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                HStack {
                    Text(t.currentSettingLabel(DurationFormatter.formatDuration(manager.initialMinutes, isChinese: t.isZh)))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    if !manager.isIndefinite {
                        Button(t.extend30mButton) {
                            manager.extendSession(byMinutes: 30)
                        }
                        .buttonStyle(BorderedButtonStyle())
                        .controlSize(.small)
                    }
                }
            }

            Button(action: {
                manager.stopSession(reason: .manual)
            }) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.red)
                        .frame(width: 9, height: 9)
                    Text(manager.isFollowingAgents ? t.autoFollowStopButton : t.stopButton)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.red)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.red.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.red.opacity(0.22), lineWidth: 1)
                )
            }
            .buttonStyle(PlainButtonStyle())

            Divider()

            HStack {
                Button(action: {
                    manager.applyURLCommand(.lock)
                    manager.onRequestClosePopover?()
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "lock")
                            .font(.system(size: 11))
                        Text(t.lockScreenButton)
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()

                Button(action: {
                    manager.stopSession(reason: .silent)
                    NSApp.terminate(nil)
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 11))
                        Text(t.quitButton)
                            .font(.system(size: 12))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Settings View

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t.settingsTitle)
                .font(.system(size: 13, weight: .semibold))

            VStack(spacing: 8) {
                autoFollowSection

                Divider()

                HStack {
                    Text(t.launchAtLoginLabel)
                        .font(.system(size: 12))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { manager.launchAtLogin },
                        set: { manager.toggleLaunchAtLogin($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(SwitchToggleStyle())
                    .controlSize(.small)
                }

                Divider()

                HStack {
                    Text(t.globalShortcutLabel)
                        .font(.system(size: 12))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { manager.config.globalShortcutEnabled },
                        set: { manager.setGlobalShortcutEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(SwitchToggleStyle())
                    .controlSize(.small)
                }

                Divider()

                cliInstallSection

                Divider()

                HStack {
                    Text(t.languageLabel)
                        .font(.system(size: 12))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { manager.config.language },
                        set: { manager.setLanguage($0) }
                    )) {
                        Text(t.languageSystem).tag(AppLanguage.system)
                        Text("中文").tag(AppLanguage.zhHans)
                        Text("English").tag(AppLanguage.en)
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
            )

            VStack(alignment: .leading, spacing: 8) {
                Button(action: {
                    manager.showAdvancedSettings.toggle()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: manager.showAdvancedSettings ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 10)
                        Text(t.advancedSettingsTitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())

                if manager.showAdvancedSettings {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(t.stopOnUnplugLabel)
                                .font(.system(size: 12))
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { manager.config.stopOnUnplug },
                                set: { manager.setStopOnUnplug($0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(SwitchToggleStyle())
                            .controlSize(.small)
                        }

                        Divider()

                        HStack {
                            Text(t.batteryCutoffLabel)
                                .font(.system(size: 12))
                            Spacer()
                            Picker("", selection: Binding(
                                get: { manager.config.batteryThresholdPercent },
                                set: { manager.setBatteryThreshold($0) }
                            )) {
                                Text(t.batteryCutoffOff).tag(0)
                                Text("5%").tag(5)
                                Text("10%").tag(10)
                                Text("15%").tag(15)
                                Text("20%").tag(20)
                            }
                            .labelsHidden()
                            .frame(width: 90)
                        }

                        Divider()

                        lidStrategyPicker(manager: manager, t: t)

                        Divider()

                        historySection
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(NSColor.controlBackgroundColor).opacity(0.45))
                    )
                }
            }

            Text(t.safetyFooterHint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            Divider()

            HStack {
                Button("v\(AppInfo.version) · GitHub") {
                    if let url = URL(string: AppInfo.repositoryURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(LinkButtonStyle())
                .font(.system(size: 11))

                Spacer()

                Button(t.quitButton) {
                    manager.stopSession(reason: .silent)
                    NSApp.terminate(nil)
                }
                .buttonStyle(BorderedButtonStyle())
                .controlSize(.small)

                Button(t.backButton) {
                    manager.showSettings = false
                }
                .buttonStyle(BorderedProminentButtonStyle())
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var cliInstallSection: some View {
        HStack {
            Text(t.cliInstallSectionLabel)
                .font(.system(size: 12))
            Spacer()
            switch manager.cliInstallStatus {
            case .installed:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                    Text(t.cliInstalledBadge)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.green)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.green.opacity(0.12)))
            case .notInstalled:
                Button(action: {
                    manager.installCLICommand()
                }) {
                    if manager.isInstallingCLI {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Text(t.cliInstallButton)
                    }
                }
                .buttonStyle(BorderedButtonStyle())
                .controlSize(.small)
                .disabled(manager.isInstallingCLI)
            case .unavailable:
                Text(t.cliUnavailableLabel)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: {
                manager.showHistory.toggle()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: manager.showHistory ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 10)
                    Text("\(t.historySectionTitle) (\(manager.history.count))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    if manager.showHistory && !manager.history.isEmpty {
                        Button(t.historyClearButton) {
                            manager.clearHistory()
                        }
                        .buttonStyle(LinkButtonStyle())
                        .font(.system(size: 10))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            if manager.showHistory {
                if manager.history.isEmpty {
                    Text(t.historyEmptyLabel)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.leading, 16)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(manager.history.prefix(5)) { entry in
                            Text(t.historyEntrySummary(entry))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(.leading, 16)
                }
            }
        }
    }

    // MARK: - Components

    /// Opt-in toggle plus the transparency copy that makes "we watch your agent's folder"
    /// acceptable: what it does, how, the privacy boundary, and the exact path watched.
    @ViewBuilder
    private var autoFollowSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(t.autoFollowLabel)
                    .font(.system(size: 12))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { manager.config.autoFollowAgents },
                    set: { manager.setAutoFollowEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle())
                .controlSize(.small)
            }

            if manager.config.autoFollowAgents {
                Text(t.autoFollowDetail)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if manager.agentSources.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.folder")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                        Text(t.autoFollowUnavailable)
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                } else {
                    let displayPaths = manager.agentSources
                        .map { abbreviateHomePath($0.path) }
                        .joined(separator: ", ")
                    Text("\(t.autoFollowWatching): \(displayPaths)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Button(action: {
                    manager.showAgentSourcesConfig.toggle()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: manager.showAgentSourcesConfig ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                        Text(t.configureAgentSourcesButton)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(PlainButtonStyle())

                if manager.showAgentSourcesConfig {
                    let allBuiltIns = AgentSource.defaults()
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], alignment: .leading, spacing: 4) {
                        ForEach(allBuiltIns, id: \.id) { source in
                            let enabled = manager.isBuiltInAgentEnabled(source.id)
                            Button(action: {
                                manager.setBuiltInAgentEnabled(source.id, enabled: !enabled)
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 9))
                                    Text(source.displayName)
                                        .font(.system(size: 10, weight: .medium))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundColor(enabled ? .accentColor : .secondary)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(enabled ? Color.accentColor.opacity(0.12) : Color(NSColor.controlColor).opacity(0.35))
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }

                    HStack {
                        Text(t.customFoldersLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: { chooseCustomFolder() }) {
                            Label(t.addFolderButton, systemImage: "folder.badge.plus")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(LinkButtonStyle())
                    }
                    .padding(.top, 2)

                    if !manager.config.customAgentPaths.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(manager.config.customAgentPaths, id: \.self) { path in
                                HStack(spacing: 6) {
                                    Text(abbreviateHomePath(path))
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Button(action: { manager.removeCustomAgentPath(path) }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(t.claudeHookSectionLabel)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(action: {
                                manager.toggleClaudeHookConnection()
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: manager.claudeHookConnected ? "checkmark.circle.fill" : "bolt.fill")
                                        .font(.system(size: 9))
                                        .foregroundColor(manager.claudeHookConnected ? .green : .accentColor)
                                    Text(manager.claudeHookConnected ? t.claudeHookDisconnectButton : t.claudeHookConnectButton)
                                        .font(.system(size: 10, weight: .medium))
                                }
                            }
                            .buttonStyle(LinkButtonStyle())
                        }
                        Text(t.claudeHookHint)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 4)
                }

                if manager.autoFollowLimitReached {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                        Text(t.autoFollowLimitNotice)
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func modeRow(
        mode: GuardMode,
        isSelected: Bool,
        badge: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: mode.iconName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(t.modeTitle(mode))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.primary)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        }
                    }
                    Text(t.modeSubtitle(mode))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? .accentColor : .secondary.opacity(0.45))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    @ViewBuilder
    private func durationChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .white : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Color.accentColor : Color(NSColor.controlBackgroundColor).opacity(0.7))
                )
        }
        .buttonStyle(PlainButtonStyle())
    }

    /// Chooses how lid-close sleep is suppressed. The two options differ in whether the user
    /// has to authorize, and in whether the suppression survives a cable being plugged back in
    /// with the lid shut — see `docs/CLAMSHELL-RESEARCH.md`.
    private func lidStrategyPicker(manager: SessionManager, t: L10n) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t.lidModeSectionTitle)
                .font(.system(size: 12))

            Picker("", selection: Binding(
                get: { manager.config.closedLidStrategy },
                set: { manager.setClosedLidStrategy($0) }
            )) {
                Text(t.lidModeStandard).tag(ClosedLidStrategy.unprivileged)
                Text(t.lidModePrivileged).tag(ClosedLidStrategy.privileged)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .font(.system(size: 11))

            Text(manager.config.closedLidStrategy == .unprivileged
                 ? t.lidModeStandardDetail
                 : t.lidModePrivilegedDetail)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chooseCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            manager.addCustomAgentPath(url.path)
        }
    }

    private func abbreviateHomePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func cardBackground(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.08) : Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    private func cardBorder(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(selected ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.12), lineWidth: 1)
    }
}
