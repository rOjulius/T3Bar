import AppKit
import Observation
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let monitor: AgentMonitor
    private let statusItem: NSStatusItem
    private let panel: FloatingGlassPanel
    private let panelHost: NSHostingController<AnyView>
    private var settingsWindow: NSWindow?

    private var globalMouseMoveMonitor: Any?
    private var localMouseMoveMonitor: Any?
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?

    private var hoverOpenTask: Task<Void, Never>?
    private var hoverDismissTask: Task<Void, Never>?
    private var openedViaHover = false
    private var outsideTicks = 0

    init(monitor: AgentMonitor) {
        self.monitor = monitor
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.panel = FloatingGlassPanel(
            contentRect: NSRect(x: 0, y: 0, width: 372, height: 320),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.panelHost = NSHostingController(rootView: AnyView(EmptyView()))
        super.init()

        setupPanel()
        setupStatusButton()
        setupGlobalMonitors()
        observeStateUpdates()
    }

    // MARK: - Panel Setup (Borderless Apple Liquid Glass Floating Panel)

    private func setupPanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isMovable = false

        let rootView = PopoverView(
            monitor: monitor,
            onOpenSettings: { [weak self] in
                self?.openSettingsWindow()
            }
        )
        panelHost.rootView = AnyView(rootView)
        panelHost.sizingOptions = [.preferredContentSize]
        panel.contentViewController = panelHost
        applyAppearance()
    }

    private func setupStatusButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleStatusButtonClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading

        renderStatusButton()
    }

    // MARK: - Global Top-Edge Hover & Outside-Click Monitors

    private func setupGlobalMonitors() {
        globalMouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePointerMoved()
            }
        }
        localMouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.handlePointerMoved()
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.panel.isVisible else { return }
                let mouse = NSEvent.mouseLocation
                if !self.isPointerInPanel(mouse) && !self.isPointerInTopEdgeStatusHitZone(mouse) {
                    self.hidePanel()
                }
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Escape
                if self.panel.isVisible {
                    self.hidePanel()
                    return nil
                }
                if let win = self.settingsWindow, win.isKeyWindow {
                    win.close()
                    return nil
                }
            }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "w" {
                if let win = self.settingsWindow, win.isKeyWindow {
                    win.close()
                    return nil
                }
            }
            return event
        }
    }

    /// Extended hit-zone that spans from the status item button ALL THE WAY up to the physical top edge of the MacBook screen.
    private func isPointerInTopEdgeStatusHitZone(_ mouse: NSPoint) -> Bool {
        guard let buttonWindow = statusItem.button?.window else { return false }
        let frame = buttonWindow.frame
        let screenMaxY = (buttonWindow.screen ?? NSScreen.main)?.frame.maxY ?? frame.maxY
        let topReach = max(frame.maxY, screenMaxY) + 4
        let hitRect = NSRect(
            x: frame.minX - 3,
            y: frame.minY - 2,
            width: frame.width + 6,
            height: max(frame.height + 4, topReach - (frame.minY - 2))
        )
        return hitRect.contains(mouse)
    }

    private func isPointerInPanel(_ mouse: NSPoint) -> Bool {
        guard panel.isVisible else { return false }
        return panel.frame.insetBy(dx: -12, dy: -12).contains(mouse)
    }

    private func handlePointerMoved() {
        guard monitor.settings.openOnHover else { return }
        let mouse = NSEvent.mouseLocation

        if isPointerInTopEdgeStatusHitZone(mouse) {
            outsideTicks = 0
            if !panel.isVisible && hoverOpenTask == nil {
                hoverOpenTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(90))
                    guard !Task.isCancelled, let self else { return }
                    guard self.monitor.settings.openOnHover else {
                        self.hoverOpenTask = nil
                        return
                    }
                    if self.isPointerInTopEdgeStatusHitZone(NSEvent.mouseLocation) && !self.panel.isVisible {
                        self.openedViaHover = true
                        self.showPanel()
                        self.startHoverDismissMonitor()
                    }
                    self.hoverOpenTask = nil
                }
            }
        } else {
            hoverOpenTask?.cancel()
            hoverOpenTask = nil
        }
    }

    // MARK: - Reactive Observation

    private func observeStateUpdates() {
        withObservationTracking {
            _ = monitor.activeCount
            _ = monitor.attentionCount
            _ = monitor.connectionState
            _ = monitor.settings.menuBarStyle
            _ = monitor.settings.appearance
            _ = monitor.settings.theme
            _ = monitor.settings.glassIntensity
            _ = monitor.settings.compactRows
            _ = monitor.settings.recentCountLimit
            _ = monitor.settings.showSubagents
            _ = monitor.allThreads.count
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.renderStatusButton()
                self?.applyAppearance()
                if self?.panel.isVisible == true {
                    self?.repositionPanel()
                }
                self?.observeStateUpdates()
            }
        }
    }

    private func applyAppearance() {
        let nsAppearance = monitor.settings.appearance.nsAppearance
        panel.appearance = nsAppearance
        settingsWindow?.appearance = nsAppearance
    }

    private func renderStatusButton() {
        guard let button = statusItem.button else { return }
        let style = monitor.settings.menuBarStyle
        let attention = monitor.attentionCount
        let active = monitor.activeCount
        let connected = monitor.connectionState.isConnected

        let symbolName: String
        let titleText: String

        if attention > 0 {
            symbolName = "exclamationmark.circle.fill"
            titleText = style == .iconOnly ? "" : " \(attention)"
        } else if active > 0 {
            symbolName = style == .dotAndCount ? "circle.fill" : "sparkle"
            titleText = style == .iconOnly ? "" : " \(active)"
        } else if !connected {
            symbolName = "circle.dotted"
            titleText = ""
        } else {
            symbolName = style == .dotAndCount ? "circle" : "sparkle"
            titleText = ""
        }

        let pointSize: CGFloat = (symbolName == "circle.fill" || symbolName == "circle") ? 9 : 13
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "T3Bar")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true

        button.image = image
        button.title = titleText
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    }

    // MARK: - Panel Presentation

    @objc private func handleStatusButtonClick(_ sender: Any?) {
        hoverOpenTask?.cancel()
        hoverOpenTask = nil

        if panel.isVisible {
            if openedViaHover {
                // Click pins the hovered panel open
                openedViaHover = false
                hoverDismissTask?.cancel()
                hoverDismissTask = nil
            } else {
                hidePanel()
            }
        } else {
            openedViaHover = false
            showPanel()
        }
    }

    private func showPanel() {
        Task { await monitor.refreshNow() }
        repositionPanel()

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        if !openedViaHover {
            panel.makeKey()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func repositionPanel() {
        guard let buttonWindow = statusItem.button?.window else { return }
        let buttonFrame = buttonWindow.frame
        let screen = buttonWindow.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        panelHost.view.layoutSubtreeIfNeeded()
        let fitting = panelHost.view.fittingSize
        let width: CGFloat = max(368, fitting.width)
        let height: CGFloat = min(max(180, fitting.height), 540)

        var originX = buttonFrame.midX - (width / 2)
        originX = max(visibleFrame.minX + 8, min(originX, visibleFrame.maxX - width - 8))
        let originY = buttonFrame.minY - height - 6

        panel.setFrame(NSRect(x: originX, y: originY, width: width, height: height), display: true)
    }

    private func hidePanel() {
        hoverDismissTask?.cancel()
        hoverDismissTask = nil
        openedViaHover = false
        outsideTicks = 0
        panel.orderOut(nil)
    }

    private func startHoverDismissMonitor() {
        hoverDismissTask?.cancel()
        outsideTicks = 0
        hoverDismissTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(140))
                guard let self, self.panel.isVisible, self.openedViaHover else { break }

                let mouse = NSEvent.mouseLocation
                // Bridge the tiny 6pt vertical gap between menu bar and panel so sliding down never closes it
                var bridgeRect = NSRect.zero
                if let bw = self.statusItem.button?.window {
                    bridgeRect = NSRect(
                        x: min(bw.frame.minX, self.panel.frame.minX),
                        y: self.panel.frame.maxY - 4,
                        width: max(bw.frame.maxX, self.panel.frame.maxX) - min(bw.frame.minX, self.panel.frame.minX),
                        height: max(16, bw.frame.minY - self.panel.frame.maxY + 12)
                    )
                }

                if self.isPointerInTopEdgeStatusHitZone(mouse) || self.isPointerInPanel(mouse) || bridgeRect.contains(mouse) {
                    self.outsideTicks = 0
                } else {
                    self.outsideTicks += 1
                    if self.outsideTicks >= 2 {
                        self.hidePanel()
                        break
                    }
                }
            }
        }
    }

    // MARK: - Settings Hub Window

    func openSettingsWindow() {
        hidePanel()

        if let existing = settingsWindow {
            existing.appearance = monitor.settings.appearance.nsAppearance
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(
            rootView: SettingsHubView(
                monitor: monitor,
                onClose: { [weak self] in
                    self?.settingsWindow?.close()
                }
            )
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "T3Bar Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.appearance = monitor.settings.appearance.nsAppearance
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = window
    }
}

private final class FloatingGlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
