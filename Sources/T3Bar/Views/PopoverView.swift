import AppKit
import SwiftUI

struct PopoverView: View {
    @Bindable var monitor: AgentMonitor
    let onOpenSettings: () -> Void

    private var theme: T3Theme { monitor.settings.theme }

    var body: some View {
        LiquidGlassContainer(
            theme: theme,
            intensity: monitor.settings.glassIntensity,
            cornerRadius: 20
        ) {
            VStack(spacing: 0) {
                headerBar
                Divider().opacity(0.35)

                if let banner = monitor.actionBanner {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Text(banner)
                            .font(.system(size: 11))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button {
                            monitor.actionBanner = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.orange.opacity(0.12))
                    Divider().opacity(0.35)
                }

                if monitor.showSetup || monitor.connectionState == .unconfigured {
                    SetupView(monitor: monitor)
                } else {
                    contentBody
                }

                Divider().opacity(0.35)
                footerBar
            }
            .frame(width: 368)
        }
        .tint(theme.accent)
        .preferredColorScheme(monitor.settings.appearance.colorScheme)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(connectionDotColor)
                    .frame(width: 7.5, height: 7.5)
                    .shadow(color: connectionDotColor.opacity(0.6), radius: 3)

                Text("T3Bar")
                    .font(.system(size: 13.5, weight: .semibold))

                Text(connectionSubtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if monitor.connectionState != .unconfigured && !monitor.showSetup {
                Button {
                    Task { await monitor.refreshNow() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(.primary.opacity(0.05), in: Circle())
                        .rotationEffect(.degrees(monitor.isRefreshing ? 360 : 0))
                        .animation(
                            monitor.isRefreshing
                                ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                                : .default,
                            value: monitor.isRefreshing
                        )
                }
                .buttonStyle(.plain)
                .help("Refresh now")
            }

            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(.primary.opacity(0.05), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Main Agent List

    private var contentBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if case .error(let msg) = monitor.connectionState {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Connection issue", systemImage: "wifi.exclamationmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text(msg)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("Retry") {
                                Task { await monitor.refreshNow() }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Settings…") {
                                onOpenSettings()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                sectionHeader("ACTIVE", count: monitor.activeCount)

                if monitor.activeTrees.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.accent.opacity(0.8))
                        Text("All quiet — no running agents.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                } else {
                    VStack(spacing: 3) {
                        ForEach(monitor.activeTrees) { tree in
                            AgentRowView(
                                thread: tree.thread,
                                projectName: tree.projectName,
                                isChild: false,
                                isStopping: monitor.stoppingThreadIds.contains(tree.thread.threadId),
                                showProjectBadge: monitor.settings.showProjectBadges,
                                showProgressLine: monitor.settings.showProgressLine,
                                compact: monitor.settings.compactRows,
                                theme: theme,
                                onOpen: { monitor.openInT3Code(tree.thread) },
                                onStop: { monitor.stopAgent(tree.thread) }
                            )

                            ForEach(tree.children) { child in
                                AgentRowView(
                                    thread: child.thread,
                                    projectName: child.projectName,
                                    isChild: true,
                                    isStopping: monitor.stoppingThreadIds.contains(child.thread.threadId),
                                    showProjectBadge: monitor.settings.showProjectBadges,
                                    showProgressLine: monitor.settings.showProgressLine,
                                    compact: monitor.settings.compactRows,
                                    theme: theme,
                                    onOpen: { monitor.openInT3Code(child.thread) },
                                    onStop: { monitor.stopAgent(child.thread) }
                                )
                            }
                        }
                    }
                }

                if !monitor.recentThreads.isEmpty {
                    Divider().opacity(0.3).padding(.vertical, 2)
                    sectionHeader("RECENT", count: monitor.recentThreads.count)

                    VStack(spacing: 2) {
                        ForEach(monitor.recentThreads) { thread in
                            AgentRowView(
                                thread: thread,
                                projectName: monitor.projectName(for: thread),
                                isChild: false,
                                isStopping: false,
                                showProjectBadge: monitor.settings.showProjectBadges,
                                showProgressLine: monitor.settings.showProgressLine,
                                compact: monitor.settings.compactRows,
                                theme: theme,
                                onOpen: { monitor.openInT3Code(thread) },
                                onStop: {}
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .frame(maxHeight: 410)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 12) {
            Button {
                onOpenSettings()
            } label: {
                Label("Settings…", systemImage: "slider.horizontal.3")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            Text(theme.displayName)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(.secondary)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(theme.accent.opacity(0.15), in: Capsule())
            }
            Spacer()
        }
        .padding(.horizontal, 6)
    }

    private var connectionDotColor: Color {
        switch monitor.connectionState {
        case .connected: return monitor.attentionCount > 0 ? .orange : .green
        case .connecting: return .yellow
        case .error: return .red
        case .unconfigured: return .secondary.opacity(0.5)
        }
    }

    private var connectionSubtitle: String {
        switch monitor.connectionState {
        case .connected:
            if monitor.attentionCount > 0 {
                return "· \(monitor.attentionCount) waiting"
            }
            if monitor.activeCount > 0 {
                return "· \(monitor.activeCount) running"
            }
            return "· idle"
        case .connecting:
            return "· connecting…"
        case .error:
            return "· offline"
        case .unconfigured:
            return "· setup"
        }
    }
}
