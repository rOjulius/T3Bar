import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case connection = "Connection"
    case notifications = "Notifications"
    case appearance = "Appearance"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .connection: return "link"
        case .notifications: return "bell.badge"
        case .appearance: return "paintbrush"
        }
    }
}

struct SettingsHubView: View {
    @Bindable var monitor: AgentMonitor
    var onClose: (() -> Void)? = nil
    @State private var selectedTab: SettingsTab = .general

    @State private var mcpURLInput: String = ""
    @State private var manualTokenInput: String = ""
    @State private var showManualOption: Bool = false
    @State private var testFeedback: String? = nil

    private var theme: T3Theme { monitor.settings.theme }

    var body: some View {
        ZStack {
            ZStack {
                VisualEffectBackdrop(material: .underWindowBackground, blendingMode: .behindWindow)
                LinearGradient(
                    colors: [
                        theme.glassBaseTint.opacity(monitor.settings.glassIntensity.tintOpacity * 0.75),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top segmented icon tab bar (CodexBar style)
                HStack(spacing: 4) {
                    ForEach(SettingsTab.allCases) { tab in
                        Button {
                            selectedTab = tab
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: tab.icon)
                                    .font(.system(size: 16, weight: .medium))
                                Text(tab.rawValue)
                                    .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .regular))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundStyle(selectedTab == tab ? theme.accent : .secondary)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(selectedTab == tab ? theme.accent.opacity(0.14) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(selectedTab == tab ? theme.accent.opacity(0.28) : Color.clear, lineWidth: 0.7)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 10)

                Divider().opacity(0.45)

                Group {
                    switch selectedTab {
                    case .general:
                        generalTab
                    case .connection:
                        connectionTab
                    case .notifications:
                        notificationsTab
                    case .appearance:
                        appearanceTab
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                Divider().opacity(0.45)

                HStack {
                    Text("T3Bar v0.4.1")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("Liquid Glass · T3 Code Themes")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    if let onClose {
                        Button("Done") {
                            onClose()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.leading, 8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .frame(width: 520, height: 520)
        .tint(theme.accent)
        .preferredColorScheme(monitor.settings.appearance.colorScheme)
        .onAppear {
            if mcpURLInput.isEmpty && !monitor.savedMCPURL.isEmpty {
                mcpURLInput = monitor.savedMCPURL
            }
            showManualOption = monitor.isConnectedWithManualToken
            if monitor.connectionState == .unconfigured {
                selectedTab = .connection
            }
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Startup & Interaction") {
                Toggle("Launch T3Bar at login", isOn: $monitor.launchAtLogin)
                Toggle("Open popover on hover (includes top screen edge)", isOn: $monitor.settings.openOnHover)
            }

            Section("Refresh Cadence") {
                Picker("When agents are running", selection: $monitor.settings.activePollSeconds) {
                    Text("Every 2s").tag(2)
                    Text("Every 3s (Default)").tag(3)
                    Text("Every 5s").tag(5)
                    Text("Every 10s").tag(10)
                }

                Picker("When idle", selection: $monitor.settings.idlePollSeconds) {
                    Text("Every 5s").tag(5)
                    Text("Every 10s (Default)").tag(10)
                    Text("Every 15s").tag(15)
                    Text("Every 30s").tag(30)
                }
            }

            Section("Agent List") {
                Picker("Recent completed runs", selection: $monitor.settings.recentCountLimit) {
                    Text("Hidden").tag(0)
                    Text("Last 3").tag(3)
                    Text("Last 5 (Default)").tag(5)
                    Text("Last 10").tag(10)
                }

                Toggle("Show nested subagents", isOn: $monitor.settings.showSubagents)
                Toggle("Show live progress line", isOn: $monitor.settings.showProgressLine)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Connection Tab

    private var connectionTab: some View {
        Form {
            Section("Status") {
                HStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .font(.system(size: 12.5, weight: .medium))
                    Spacer()
                    if monitor.connectionState.isConnected {
                        Text("\(monitor.projectsById.count) projects · \(monitor.allThreads.count) threads")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("T3 Code MCP Endpoint") {
                TextField("https://.../mcp  or  http://127.0.0.1:.../mcp", text: $mcpURLInput)
                    .font(.system(size: 12, design: .monospaced))

                Toggle("Use manual Bearer token / local URL", isOn: $showManualOption)

                if showManualOption {
                    SecureField("Bearer token (leave empty if unauthenticated)", text: $manualTokenInput)
                        .font(.system(size: 12, design: .monospaced))
                }

                if let err = monitor.authError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }

                HStack(spacing: 10) {
                    if showManualOption {
                        Button(monitor.isAuthorizing ? "Connecting…" : "Save & Connect") {
                            monitor.connectWithManualToken(mcpURL: mcpURLInput, bearerToken: manualTokenInput)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(monitor.isAuthorizing || mcpURLInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    } else {
                        Button(monitor.isAuthorizing ? "Waiting for browser…" : "Sign in with T3 Code") {
                            monitor.connectWithOAuth(mcpURL: mcpURLInput)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(monitor.isAuthorizing || mcpURLInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if monitor.connectionState.isConnected {
                        Button("Refresh Now") {
                            Task { await monitor.refreshNow() }
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer()

                    if !monitor.savedMCPURL.isEmpty {
                        Button("Disconnect", role: .destructive) {
                            monitor.disconnect()
                            mcpURLInput = ""
                            manualTokenInput = ""
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Notifications Tab

    private var notificationsTab: some View {
        Form {
            Section("macOS Notifications") {
                Toggle("Enable notifications", isOn: $monitor.notificationsEnabled)
            }

            Section("Events") {
                Toggle("Agent finished (completed)", isOn: $monitor.settings.notifyOnCompleted)
                    .disabled(!monitor.notificationsEnabled)
                Toggle("Agent failed (error)", isOn: $monitor.settings.notifyOnFailed)
                    .disabled(!monitor.notificationsEnabled)
                Toggle("Agent needs your input", isOn: $monitor.settings.notifyOnNeedsInput)
                    .disabled(!monitor.notificationsEnabled)
            }

            Section("Verification") {
                HStack {
                    Button("Send Test Notification") {
                        monitor.sendTestNotification()
                        testFeedback = "Sent — check Notification Center if banners are muted."
                    }
                    .disabled(!monitor.notificationsEnabled)

                    Spacer()

                    if let testFeedback {
                        Text(testFeedback)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Appearance Tab (T3 Code Themes + Liquid Glass)

    private var appearanceTab: some View {
        Form {
            Section("T3 Code Color Theme") {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)
                    ],
                    spacing: 8
                ) {
                    ForEach(T3Theme.allCases) { item in
                        ThemeSwatchCard(
                            theme: item,
                            isSelected: monitor.settings.theme == item,
                            onSelect: { monitor.settings.theme = item }
                        )
                    }
                }
                .padding(.vertical, 4)

                Picker("Appearance", selection: $monitor.settings.appearance) {
                    ForEach(AppAppearance.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Liquid Glass Tint", selection: $monitor.settings.glassIntensity) {
                    ForEach(GlassIntensity.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Menu Bar & Popover") {
                Picker("Indicator style", selection: $monitor.settings.menuBarStyle) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Open popover on hover", isOn: $monitor.settings.openOnHover)
                Toggle("Compact rows", isOn: $monitor.settings.compactRows)
                Toggle("Show project badges", isOn: $monitor.settings.showProjectBadges)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch monitor.connectionState {
        case .connected: return .green
        case .connecting: return .yellow
        case .error: return .red
        case .unconfigured: return .secondary
        }
    }

    private var statusText: String {
        switch monitor.connectionState {
        case .connected(let date):
            return "Connected (updated \(RelativeTimeFormatter.string(from: date)))"
        case .connecting:
            return "Connecting…"
        case .error(let msg):
            return "Error: \(msg)"
        case .unconfigured:
            return "Not connected"
        }
    }
}

private struct ThemeSwatchCard: View {
    let theme: T3Theme
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [theme.swatchSurface, theme.glassBaseTint.opacity(0.65)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 24, height: 24)
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 10, height: 10)
                        .shadow(color: theme.accent.opacity(0.6), radius: 2)
                }

                Text(theme.displayName)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? theme.accent.opacity(0.14) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? theme.accent.opacity(0.75) : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.2 : 0.7)
            )
        }
        .buttonStyle(.plain)
    }
}
