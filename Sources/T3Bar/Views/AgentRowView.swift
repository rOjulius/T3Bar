import SwiftUI

struct AgentRowView: View {
    let thread: T3Thread
    let projectName: String?
    let isChild: Bool
    let isStopping: Bool
    let showProjectBadge: Bool
    let showProgressLine: Bool
    let compact: Bool
    let theme: T3Theme
    let onOpen: () -> Void
    let onStop: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isChild {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
                    .padding(.leading, 8)
            }

            StatusIndicatorDot(thread: thread)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(thread.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    if thread.status.isActive, let start = thread.effectiveStartDate {
                        ElapsedTimerText(since: start)
                    } else if let updated = thread.updatedAt {
                        Text(RelativeTimeFormatter.string(from: updated))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }

                HStack(spacing: 5) {
                    if showProjectBadge, let projectName, !projectName.isEmpty, !isChild {
                        Text(projectName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(theme.accent.opacity(0.14), in: Capsule())
                            .lineLimit(1)
                    }

                    Text(thread.shortModelName)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if thread.needsAttention {
                        Text("Needs input")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.14), in: Capsule())
                    } else if !thread.status.isActive {
                        Text(thread.status.displayLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(statusColor)
                    }
                }

                if showProgressLine && thread.status.isActive {
                    Text(thread.latestStepText ?? "\(thread.status.displayLabel)…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            if thread.status.isActive {
                Button(action: onStop) {
                    if isStopping {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(isHovered ? Color.red.opacity(0.9) : Color.secondary.opacity(0.55))
                    }
                }
                .buttonStyle(.plain)
                .help("Stop agent")
                .disabled(isStopping)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, compact ? 5 : 7.5)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(rowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(rowBorder, lineWidth: 0.6)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            onOpen()
        }
    }

    private var rowBackground: Color {
        if thread.needsAttention {
            return isHovered ? Color.orange.opacity(0.18) : Color.orange.opacity(0.10)
        }
        if isHovered {
            return theme.accent.opacity(0.14)
        }
        return thread.status.isActive ? Color.primary.opacity(0.035) : Color.clear
    }

    private var rowBorder: Color {
        if thread.needsAttention {
            return Color.orange.opacity(0.35)
        }
        if isHovered {
            return theme.accent.opacity(0.28)
        }
        return thread.status.isActive ? Color.primary.opacity(0.06) : Color.clear
    }

    private var statusColor: Color {
        switch thread.status {
        case .completed: return .green
        case .failed: return .red
        case .interrupted, .cancelled: return .secondary
        default: return .secondary
        }
    }
}

private struct StatusIndicatorDot: View {
    let thread: T3Thread
    @State private var pulse = false

    var body: some View {
        ZStack {
            if thread.status.isActive {
                Circle()
                    .fill(dotColor.opacity(0.28))
                    .frame(width: 11, height: 11)
                    .scaleEffect(pulse ? 1.25 : 0.85)
                    .opacity(pulse ? 0.2 : 0.7)
                    .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: pulse)
            }
            Circle()
                .fill(dotColor)
                .frame(width: 6.5, height: 6.5)
        }
        .frame(width: 11, height: 11)
        .onAppear {
            if thread.status.isActive { pulse = true }
        }
    }

    private var dotColor: Color {
        if thread.needsAttention { return .orange }
        switch thread.status {
        case .running, .starting, .preparing: return .green
        case .queued: return .blue
        case .completed: return .green.opacity(0.75)
        case .failed: return .red
        default: return .secondary.opacity(0.6)
        }
    }
}

private struct ElapsedTimerText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.format(interval: max(0, context.date.timeIntervalSince(since))))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private static func format(interval: TimeInterval) -> String {
        let total = Int(interval)
        let hours = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%dh %02dm", hours, mins)
        }
        return String(format: "%02d:%02d", mins, secs)
    }
}

enum RelativeTimeFormatter {
    static func string(from date: Date) -> String {
        let secs = Int(max(0, Date().timeIntervalSince(date)))
        if secs < 60 { return "now" }
        let mins = secs / 60
        if mins < 60 { return "\(mins)m" }
        let hours = mins / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}
