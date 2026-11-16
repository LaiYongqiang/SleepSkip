import Cocoa
import SleepSkipCore
import SwiftUI

final class PopoverLayoutModel: ObservableObject {
    @Published var maxPopoverHeight: CGFloat = 560
}

struct SleepSkipPopoverView: View {
    @ObservedObject var manager: SessionManager
    @ObservedObject var layoutModel: PopoverLayoutModel

    init(manager: SessionManager, layoutModel: PopoverLayoutModel = PopoverLayoutModel()) {
        self.manager = manager
        self.layoutModel = layoutModel
    }

    private var t: L10n { manager.l10n }

    var body: some View {
        VStack(spacing: 12) {
            headerBar

            if manager.showSettings {
                settingsPinnedHeaderBanners
                settingsContent
            } else {
                mainPinnedTopBanners
                mainViewBody
            }
        }
        .padding(16)
        .frame(width: 372)
        .frame(maxHeight: layoutModel.maxPopoverHeight)
        // NSPopover's own background is translucent, so without an opaque fill the desktop and
        // the menu bar behind it show through and the whole panel reads as washed-out grey.
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private var mainViewBody: some View {
        ViewThatFits(in: .vertical) {
            mainViewStack
            ScrollView(.vertical, showsIndicators: true) {
                mainViewStack
                    .padding(.trailing, 4)
            }
        }
    }

    @ViewBuilder
    private var mainPinnedTopBanners: some View {
        if let error = manager.errorMessage {
            errorBanner(error)
        } else if manager.staleSleepDisabled && !manager.isRunning {
            staleSleepBanner
        }

        if manager.isAuthorizing {
            authorizingBanner
        }
    }

    @ViewBuilder
    private var mainViewStack: some View {
        VStack(spacing: 12) {
            if let cli = manager.externalCLI {
                cliBanner(cli)
            }

            if manager.showAutoFollowNotice {
                autoFollowNotice
            }

            if manager.isRunning {
                runningContent
            } else {
                idleContent
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(nsImage: StatusBarIcon.image(active: manager.isEffectivelyActive))
                .renderingMode(.template)
                .foregroundColor(manager.isEffectivelyActive ? .accentColor : .primary)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)

            Text(t.appName)
                .font(.system(size: 14, weight: .semibold))

            if manager.isAuthorizing {
                statusBadge(t.authorizingBadge, color: .orange)
            } else if manager.isFollowingAgents {
                // Auto-follow reads as a different thing from a session the user started.
                statusBadge(t.autoFollowBadge, color: .blue)
            } else if manager.isRunning {
                statusBadge(manager.activeClosedLid ? t.backpackBadge : t.runningBadge, color: .green)
            } else if manager.autoFollowSuppressed {
                statusBadge(t.pausedBadge, color: .orange)
            } else if manager.externalCLI != nil {
                statusBadge("CLI", color: .blue)
            }

            Spacer()

            Button(action: {
                manager.refreshClaudeHookStatus()
                manager.showSettings.toggle()
            }) {
                Image(systemName: manager.showSettings ? "xmark.circle.fill" : "gearshape")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .help(manager.showSettings ? t.backButton : t.settingsTitle)
            .accessibilityLabel(manager.showSettings ? t.backButton : t.settingsTitle)
        }
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    // MARK: - Banners

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(.red)
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: { manager.errorMessage = nil }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel(t.dismissErrorA11y)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.red.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.red.opacity(0.25), lineWidth: 1)
        )
    }

    /// Shown once, on first launch, because directory watching is on by default.
    private var autoFollowNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                    .accessibilityHidden(true)
                Text(t.autoFollowNoticeTitle)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: { manager.dismissAutoFollowNotice() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel(t.dismissNoticeA11y)
            }
            Text(t.autoFollowNoticeBody)
                .font(.system(size: 11))
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
                .accessibilityHidden(true)
            Text(t.staleSleepDisabledBanner)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(t.restoreSleepButton) {
                manager.restoreStaleSleepDisabled()
            }
            .buttonStyle(BorderedButtonStyle())
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }

    private func cliBanner(_ cli: ExternalCLISession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.blue)
                    .accessibilityHidden(true)
                Text(t.cliGuardingBanner(cli))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            Text(t.cliGuardingDetail)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.blue.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.blue.opacity(0.22), lineWidth: 1)
        )
    }

    private var authorizingBanner: some View {
        let pendingSummary: String = {
            if let p = manager.pendingAuthorizationLaunch {
                return t.compactConfigDescription(
                    mode: p.mode,
                    durationMinutes: p.durationMinutes,
                    lockOnStart: p.lockOnStart,
                    closedLid: true
                )
            }
            return t.compactConfigDescription(
                mode: manager.config.mode,
                durationMinutes: manager.config.durationMinutes,
                lockOnStart: manager.config.effectiveLockOnStart,
                closedLid: manager.config.effectiveAllowClosedLid
            )
        }()

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(t.authorizingTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
            }
            Text(t.authorizingDetail(pendingSummary))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(t.cancelLaunchButton) {
                    manager.cancelAuthorization()
                }
                .buttonStyle(BorderedButtonStyle())
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.orange.opacity(0.28), lineWidth: 1)
        )
    }

    // MARK: - Idle View

    private var idleContent: some View {
        VStack(spacing: 12) {
            idleStatusCard

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(t.modeSectionTitle)
                        .font(.system(size: 12, weight: .medium))
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
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(t.closedLidInlineNote(strategy: manager.config.closedLidStrategy))
                                        .font(.system(size: 11))
                                        .foregroundColor(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Button(t.changeClosedLidMethodButton) {
                                        manager.refreshClaudeHookStatus()
                                        manager.showSettings = true
                                    }
                                    .buttonStyle(LinkButtonStyle())
                                    .font(.system(size: 11))
                                }
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
            .disabled(manager.isAuthorizing)
            .opacity(manager.isAuthorizing ? 0.65 : 1.0)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(t.durationSectionTitle)
                        .font(.system(size: 12, weight: .medium))
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
                            accessibleTitle: DurationFormatter.formatDuration(min, isChinese: t.isZh),
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
                    let customAccessible = isCustomSelected
                        ? DurationFormatter.formatDuration(manager.config.durationMinutes, isChinese: t.isZh)
                        : t.customDuration
                    durationChip(
                        title: customLabel,
                        accessibleTitle: customAccessible,
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
                        .accessibilityLabel(t.customDuration)
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
            .disabled(manager.isAuthorizing)
            .opacity(manager.isAuthorizing ? 0.65 : 1.0)

            Button(action: {
                manager.startConfiguredSession()
            }) {
                HStack(spacing: 6) {
                    if manager.isAuthorizing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: manager.config.effectiveLockOnStart ? "lock.fill" : "play.fill")
                            .font(.system(size: 11))
                            .accessibilityHidden(true)
                    }
                    Text(t.startButtonTitle(for: manager.config))
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(manager.isAuthorizing ? 0.55 : 1.0))
                )
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(manager.isAuthorizing)
        }
    }

    @ViewBuilder
    private var idleStatusCard: some View {
        let watchFoldersOn = manager.config.autoFollowAgents
        let hasFolders = !manager.agentSources.isEmpty
        let hookOn = manager.claudeHookConnected

        if manager.autoFollowSuppressed {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 7, height: 7)
                    Text(manager.autoFollowLimitReached ? t.autoFollowLimitTitle : t.autoFollowPausedTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                }
                Text(t.autoFollowPausedDetail(
                    sourceKind: manager.activeAutoFollowSourceKind,
                    limitReached: manager.autoFollowLimitReached
                ))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)

                Button(t.resumeAutoFollowButton) {
                    manager.resumeAutoFollow()
                }
                .buttonStyle(BorderedButtonStyle())
                .controlSize(.small)

                Text(t.launchConfigSummary(manager.config))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.orange.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.orange.opacity(0.24), lineWidth: 1)
            )
        } else if watchFoldersOn && !hasFolders && !hookOn {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 7, height: 7)
                    Text(t.idleNoSourcesTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                }
                Text(t.idleNoSourcesDetail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)

                Button(t.configureSourcesAction) {
                    manager.refreshClaudeHookStatus()
                    manager.showAgentSourcesConfig = true
                    manager.showSettings = true
                }
                .buttonStyle(BorderedButtonStyle())
                .controlSize(.small)

                Text(t.launchConfigSummary(manager.config))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.orange.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.orange.opacity(0.22), lineWidth: 1)
            )
        } else {
            let statusMeta: (title: String, dotColor: Color, primary: Bool) = {
                if watchFoldersOn && hasFolders && hookOn {
                    return (t.idleFoldersAndHookTitle, .blue, true)
                }
                if watchFoldersOn && hasFolders {
                    return (t.idleFoldersOnlyTitle, .blue, true)
                }
                if hookOn {
                    return (t.idleHookOnlyTitle, .blue, true)
                }
                return (t.notRunningTitle, Color.secondary.opacity(0.45), false)
            }()

            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusMeta.dotColor.opacity(statusMeta.primary ? 0.85 : 1.0))
                        .frame(width: 7, height: 7)
                    Text(statusMeta.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(statusMeta.primary ? .primary : .secondary)
                }
                Text(t.launchConfigSummary(manager.config))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
            )
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
        let modeSummary = t.modeTitle(manager.activeMode)

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

                let lidPart = manager.activeClosedLid ? " · \(t.backpackBadge)" : ""
                if manager.isFollowingAgents {
                    let agentsText = t.autoFollowAgentsLabel(manager.followingAgents)
                    let sourceLine = agentsText.isEmpty
                        ? "\(t.autoFollowBadge) · \(modeSummary)"
                        : "\(t.autoFollowBadge) · \(agentsText) · \(modeSummary)"
                    Text(sourceLine)
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
                            return isGracePhase
                                ? t.autoFollowGraceDetail(timeText)
                                : t.autoFollowCeilingLabel(timeText, sourceKind: manager.activeAutoFollowSourceKind)
                        }
                        return t.projectedEndLabel(timeText)
                    }()
                    Text(detailText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
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
                    .font(.system(size: 12, weight: .medium))
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

                if manager.isFollowingAgents {
                    Text(t.modeSwitchAutoFollowNote)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if manager.isFollowingAgents {
                VStack(alignment: .leading, spacing: 6) {
                    Text(t.autoFollowPolicySummary(manager.activeAutoFollowSourceKind))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    let manualDurationText = DurationFormatter.formatDuration(
                        manager.config.durationMinutes,
                        isChinese: t.isZh
                    )
                    Button(t.switchToManualButton(manualDurationText)) {
                        manager.promoteAutoFollowToManual()
                    }
                    .buttonStyle(LinkButtonStyle())
                    .font(.system(size: 11))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
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

                    if manager.canSwitchToAutoFollow {
                        if manager.pendingAutoFollowSwitchConfirmation {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(t.confirmAutoFollowSwitchTitle)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(t.confirmAutoFollowSwitchDetail)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 8) {
                                    Button(t.confirmAutoFollowSwitchButton) {
                                        manager.switchManualToAutoFollow()
                                    }
                                    .buttonStyle(BorderedButtonStyle())
                                    .controlSize(.small)
                                    .tint(.orange)

                                    Button(t.keepClosedLidSessionButton) {
                                        manager.cancelSwitchToAutoFollow()
                                    }
                                    .buttonStyle(BorderedButtonStyle())
                                    .controlSize(.small)
                                }
                            }
                            .padding(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.orange.opacity(0.1))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.orange.opacity(0.28), lineWidth: 1)
                            )
                        } else {
                            Button(t.returnToAutoFollowButton(dropsClosedLid: manager.activeClosedLid)) {
                                manager.requestSwitchManualToAutoFollow()
                            }
                            .buttonStyle(LinkButtonStyle())
                            .font(.system(size: 11))
                        }
                    }
                }
            }

            VStack(spacing: 4) {
                Button(action: {
                    manager.stopSession(reason: .manual)
                }) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.red)
                            .frame(width: 9, height: 9)
                            .accessibilityHidden(true)
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

                Text(t.stopSessionClarification)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button(action: {
                    manager.applyURLCommand(.lock)
                    manager.onRequestClosePopover?()
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "lock")
                            .font(.system(size: 11))
                            .accessibilityHidden(true)
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
                            .accessibilityHidden(true)
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

    @ViewBuilder
    private var settingsPinnedHeaderBanners: some View {
        if manager.isAuthorizing {
            authorizingBanner
        } else if manager.isRunning {
            activeSettingsStatusBar
        }

        if let error = manager.errorMessage {
            errorBanner(error)
        } else if manager.staleSleepDisabled && !manager.isRunning {
            staleSleepBanner
        }
    }

    private var activeSettingsStatusBar: some View {
        let isGracePhase = manager.isFollowingAgents && manager.autoFollowGraceEndDate != nil
        let statusColor: Color = isGracePhase ? .orange : .green
        let remainingText: String = {
            if manager.isIndefinite { return t.indefiniteRunning }
            let sec = isGracePhase ? manager.autoFollowGraceRemainingSeconds : manager.remainingSeconds
            return DurationFormatter.formatCountdown(sec)
        }()
        let subtitle: String = {
            let mode = t.modeTitle(manager.activeMode)
            if manager.isFollowingAgents {
                let agents = t.autoFollowAgentsLabel(manager.followingAgents)
                return agents.isEmpty ? "\(t.autoFollowBadge) · \(mode)" : "\(agents) · \(mode)"
            }
            return manager.activeClosedLid ? "\(mode) · \(t.backpackBadge)" : mode
        }()

        return HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(manager.isFollowingAgents ? t.autoFollowBadge : t.runningBadge) · \(remainingText)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button(manager.isFollowingAgents ? t.autoFollowStopButton : t.stopButton) {
                manager.stopSession(reason: .manual)
            }
            .buttonStyle(BorderedButtonStyle())
            .controlSize(.small)
            .tint(.red)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(statusColor.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(statusColor.opacity(0.24), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(t.activeStatusSummaryA11y(mode: subtitle, remaining: remainingText))
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t.settingsTitle)
                .font(.system(size: 13, weight: .semibold))

            ViewThatFits(in: .vertical) {
                settingsScrollBody
                ScrollView(.vertical, showsIndicators: true) {
                    settingsScrollBody
                        .padding(.trailing, 4)
                }
            }

            Text(t.safetyFooterHint)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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

    private var settingsScrollBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let cli = manager.externalCLI {
                cliBanner(cli)
            }

                    // 1. Folder watching card
                    VStack(alignment: .leading, spacing: 8) {
                        autoFollowSection
                    }
                    .padding(10)
                    .background(settingsCardBackground)

                    // 2. Claude Code Hook card (always visible and independent)
                    VStack(alignment: .leading, spacing: 8) {
                        claudeHookSection
                    }
                    .padding(10)
                    .background(settingsCardBackground)

                    // 3. General card
                    VStack(alignment: .leading, spacing: 8) {
                        Text(t.generalSectionTitle)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)

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
                            .accessibilityLabel(t.launchAtLoginLabel)
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
                            .accessibilityLabel(t.globalShortcutLabel)
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
                            .frame(width: 120)
                            .accessibilityLabel(t.languageLabel)
                        }
                    }
                    .padding(10)
                    .background(settingsCardBackground)

                    // 4. Power, Thermal & Lid card (flat, no nested disclosure)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(t.powerAndLidSectionTitle)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)

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
                            .accessibilityLabel(t.stopOnUnplugLabel)
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
                            .frame(width: 100)
                            .accessibilityLabel(t.batteryCutoffLabel)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(t.thermalCutoffLabel)
                                    .font(.system(size: 12))
                                Spacer()
                                Picker("", selection: Binding(
                                    get: { manager.config.thermalCutoff },
                                    set: { manager.setThermalCutoff($0) }
                                )) {
                                    ForEach(ThermalCutoff.allCases) { level in
                                        Text(t.thermalCutoffName(level)).tag(level)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 100)
                                .accessibilityLabel(t.thermalCutoffLabel)
                            }
                            Text(t.thermalCutoffHint)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Divider()

                        lidStrategyPicker(manager: manager, t: t)
                    }
                    .padding(10)
                    .background(settingsCardBackground)

                    // 5. Recent Sessions card
                    VStack(alignment: .leading, spacing: 8) {
                        historySection
                    }
                    .padding(10)
                    .background(settingsCardBackground)
        }
    }

    private var settingsCardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
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
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                        .accessibilityHidden(true)
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
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button(action: {
                    manager.showHistory.toggle()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: manager.showHistory ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 12)
                            .accessibilityHidden(true)
                        Text("\(t.historySectionTitle) (\(manager.history.count))")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.primary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("\(t.historySectionTitle) (\(manager.history.count))")
                .accessibilityValue(manager.showHistory ? t.expandedA11y : t.collapsedA11y)

                if manager.showHistory && !manager.history.isEmpty {
                    Button(t.historyClearButton) {
                        manager.clearHistory()
                    }
                    .buttonStyle(LinkButtonStyle())
                    .font(.system(size: 11))
                }
            }

            if manager.showHistory {
                if manager.history.isEmpty {
                    Text(t.historyEmptyLabel)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(manager.history.prefix(5)) { entry in
                            Text(t.historyEntrySummary(entry))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Folder Watching & Independent Hook Sections

    @ViewBuilder
    private var autoFollowSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(t.autoFollowLabel)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { manager.config.autoFollowAgents },
                    set: { manager.setAutoFollowEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle())
                .controlSize(.small)
                .accessibilityLabel(t.autoFollowLabel)
            }

            Text(t.autoFollowDetail)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if manager.config.autoFollowAgents {
                if manager.agentSources.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.folder")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                            .accessibilityHidden(true)
                        Text(t.autoFollowUnavailable)
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    let displayPaths = manager.agentSources
                        .map { abbreviateHomePath($0.path) }
                        .joined(separator: ", ")
                    Text("\(t.autoFollowWatching): \(displayPaths)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: {
                    manager.showAgentSourcesConfig.toggle()
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: manager.showAgentSourcesConfig ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .accessibilityHidden(true)
                        Text(t.configureAgentSourcesButton)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel(t.configureAgentSourcesButton)
                .accessibilityValue(manager.showAgentSourcesConfig ? t.expandedA11y : t.collapsedA11y)

                if manager.showAgentSourcesConfig {
                    agentSourcesGrid

                    HStack {
                        Text(t.customFoldersLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: { chooseCustomFolder() }) {
                            Label(t.addFolderButton, systemImage: "folder.badge.plus")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(LinkButtonStyle())
                    }
                    .padding(.top, 2)

                    if !manager.config.customAgentPaths.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(manager.config.customAgentPaths, id: \.self) { path in
                                let shortPath = abbreviateHomePath(path)
                                HStack(spacing: 6) {
                                    Text(shortPath)
                                        .font(.system(size: 11))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Button(action: { manager.removeCustomAgentPath(path) }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                            .frame(width: 18, height: 18)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .help(t.removeFolderA11y(shortPath))
                                    .accessibilityLabel(t.removeFolderA11y(shortPath))
                                }
                            }
                        }
                    }
                }

                if manager.autoFollowLimitReached {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                            .accessibilityHidden(true)
                        Text(t.autoFollowLimitNotice)
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var agentSourcesGrid: some View {
        let allBuiltIns = AgentSource.defaults()
        let rowCount = (allBuiltIns.count + 1) / 2
        return VStack(spacing: 5) {
            ForEach(0..<rowCount, id: \.self) { row in
                HStack(spacing: 6) {
                    let first = allBuiltIns[row * 2]
                    agentSourceToggleButton(first)
                    if row * 2 + 1 < allBuiltIns.count {
                        agentSourceToggleButton(allBuiltIns[row * 2 + 1])
                    } else {
                        Spacer().frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func agentSourceToggleButton(_ source: AgentSource) -> some View {
        let enabled = manager.isBuiltInAgentEnabled(source.id)
        return Button(action: {
            manager.setBuiltInAgentEnabled(source.id, enabled: !enabled)
        }) {
            HStack(spacing: 5) {
                Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .accessibilityHidden(true)
                Text(source.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundColor(enabled ? .accentColor : .secondary)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(enabled ? Color.accentColor.opacity(0.12) : Color(NSColor.controlColor).opacity(0.35))
            )
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(source.displayName)
        .accessibilityValue(enabled ? t.enabledA11y : t.disabledA11y)
        .accessibilityAddTraits(enabled ? [.isSelected] : [])
    }

    private var claudeHookSection: some View {
        let hookStatus = manager.hookProtectionStatus
        let statusColor: Color = {
            switch hookStatus {
            case .none: return .secondary
            case .holding: return .blue
            case .paused: return .orange
            case .standbyBehindManual: return .secondary
            }
        }()

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(t.claudeHookSectionLabel)
                    .font(.system(size: 12, weight: .semibold))
                statusBadge(t.claudeHookIndependentBadge, color: .secondary)
                Spacer()
                if let badge = t.claudeHookStatusBadge(hookStatus) {
                    statusBadge(badge, color: statusColor)
                }
            }

            HStack {
                HStack(spacing: 5) {
                    Circle()
                        .fill(manager.claudeHookConnected ? Color.green : Color.secondary.opacity(0.45))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(manager.claudeHookConnected ? t.claudeHookConnectedBadge : t.claudeHookDisconnectedBadge)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(manager.claudeHookConnected ? .primary : .secondary)
                }
                Spacer()
                Button(manager.claudeHookConnected ? t.claudeHookDisconnectButton : t.claudeHookConnectButton) {
                    manager.toggleClaudeHookConnection()
                }
                .buttonStyle(BorderedButtonStyle())
                .controlSize(.small)
            }

            if let detail = t.claudeHookStatusDetail(hookStatus) {
                HStack(spacing: 6) {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(statusColor == .orange ? .orange : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .paused = hookStatus {
                        Spacer(minLength: 4)
                        Button(t.resumeAutoFollowButton) {
                            manager.resumeAutoFollow()
                        }
                        .buttonStyle(BorderedButtonStyle())
                        .controlSize(.small)
                    }
                }
            }

            Text(t.claudeHookHint)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Components

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
                    .accessibilityHidden(true)

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
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? .accentColor : .secondary.opacity(0.45))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("\(t.modeTitle(mode)), \(t.modeSubtitle(mode))")
        .accessibilityValue(isSelected ? t.selectedA11y : t.notSelectedA11y)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private func durationChip(
        title: String,
        accessibleTitle: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
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
        .accessibilityLabel(accessibleTitle)
        .accessibilityValue(selected ? t.selectedA11y : t.notSelectedA11y)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
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
            .accessibilityLabel(t.lidModeSectionTitle)

            Text(manager.config.closedLidStrategy == .unprivileged
                 ? t.lidModeStandardDetail
                 : t.lidModePrivilegedDetail)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chooseCustomFolder() {
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = false
            NSApp.activate(ignoringOtherApps: true)
            panel.begin { response in
                if response == .OK, let url = panel.url {
                    manager.addCustomAgentPath(url.path)
                }
            }
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
