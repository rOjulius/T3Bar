import Foundation
import Observation

enum MenuBarIconStyle: String, CaseIterable, Identifiable, Sendable {
    case iconAndCount = "icon_count"
    case dotAndCount = "dot_count"
    case iconOnly = "icon_only"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .iconAndCount: return "Icon + Count"
        case .dotAndCount: return "Dot + Count"
        case .iconOnly: return "Icon Only"
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var activePollSeconds: Int {
        didSet { defaults.set(activePollSeconds, forKey: "t3bar.activePollSeconds") }
    }

    var idlePollSeconds: Int {
        didSet { defaults.set(idlePollSeconds, forKey: "t3bar.idlePollSeconds") }
    }

    var recentCountLimit: Int {
        didSet { defaults.set(recentCountLimit, forKey: "t3bar.recentCountLimit") }
    }

    var showSubagents: Bool {
        didSet { defaults.set(showSubagents, forKey: "t3bar.showSubagents") }
    }

    var showProgressLine: Bool {
        didSet { defaults.set(showProgressLine, forKey: "t3bar.showProgressLine") }
    }

    var showProjectBadges: Bool {
        didSet { defaults.set(showProjectBadges, forKey: "t3bar.showProjectBadges") }
    }

    var compactRows: Bool {
        didSet { defaults.set(compactRows, forKey: "t3bar.compactRows") }
    }

    var menuBarStyle: MenuBarIconStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: "t3bar.menuBarStyle") }
    }

    var openOnHover: Bool {
        didSet { defaults.set(openOnHover, forKey: "t3bar.openOnHover") }
    }

    var theme: T3Theme {
        didSet { defaults.set(theme.rawValue, forKey: "t3bar.theme") }
    }

    var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: "t3bar.appearance") }
    }

    var glassIntensity: GlassIntensity {
        didSet { defaults.set(glassIntensity.rawValue, forKey: "t3bar.glassIntensity") }
    }

    var notifyOnCompleted: Bool {
        didSet { defaults.set(notifyOnCompleted, forKey: "t3bar.notifyOnCompleted") }
    }

    var notifyOnFailed: Bool {
        didSet { defaults.set(notifyOnFailed, forKey: "t3bar.notifyOnFailed") }
    }

    var notifyOnNeedsInput: Bool {
        didSet { defaults.set(notifyOnNeedsInput, forKey: "t3bar.notifyOnNeedsInput") }
    }

    init() {
        let d = UserDefaults.standard
        let activePoll = d.integer(forKey: "t3bar.activePollSeconds")
        self.activePollSeconds = activePoll > 0 ? activePoll : 3

        let idlePoll = d.integer(forKey: "t3bar.idlePollSeconds")
        self.idlePollSeconds = idlePoll > 0 ? idlePoll : 10

        if d.object(forKey: "t3bar.recentCountLimit") != nil {
            self.recentCountLimit = d.integer(forKey: "t3bar.recentCountLimit")
        } else {
            self.recentCountLimit = 5
        }

        self.showSubagents = (d.object(forKey: "t3bar.showSubagents") as? Bool) ?? true
        self.showProgressLine = (d.object(forKey: "t3bar.showProgressLine") as? Bool) ?? true
        self.showProjectBadges = (d.object(forKey: "t3bar.showProjectBadges") as? Bool) ?? true
        self.compactRows = (d.object(forKey: "t3bar.compactRows") as? Bool) ?? false

        if let raw = d.string(forKey: "t3bar.menuBarStyle"),
           let style = MenuBarIconStyle(rawValue: raw) {
            self.menuBarStyle = style
        } else {
            self.menuBarStyle = .iconAndCount
        }

        self.openOnHover = (d.object(forKey: "t3bar.openOnHover") as? Bool) ?? true

        if let rawTheme = d.string(forKey: "t3bar.theme"),
           let parsedTheme = T3Theme(rawValue: rawTheme) {
            self.theme = parsedTheme
        } else {
            self.theme = .grove
        }

        if let rawAppearance = d.string(forKey: "t3bar.appearance"),
           let parsedAppearance = AppAppearance(rawValue: rawAppearance) {
            self.appearance = parsedAppearance
        } else {
            self.appearance = .system
        }

        if let rawGlass = d.string(forKey: "t3bar.glassIntensity"),
           let parsedGlass = GlassIntensity(rawValue: rawGlass) {
            self.glassIntensity = parsedGlass
        } else {
            self.glassIntensity = .balanced
        }

        self.notifyOnCompleted = (d.object(forKey: "t3bar.notifyOnCompleted") as? Bool) ?? true
        self.notifyOnFailed = (d.object(forKey: "t3bar.notifyOnFailed") as? Bool) ?? true
        self.notifyOnNeedsInput = (d.object(forKey: "t3bar.notifyOnNeedsInput") as? Bool) ?? true
    }
}
