import SwiftUI

// ATOMIC LEVEL: Foundations (theme layer).
// How a Theme reaches views: the `\.theme` environment value, the persisted choice, and the
// shape styles that resolve a colour role in the current theme with Increase Contrast applied.

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.blackGlass
}

extension EnvironmentValues {
    /// The app-wide theme. Black glass unless a root sets another.
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// The person's theme choice, kept in user defaults under `appearance.theme`. Console until they
/// choose; black glass stays on offer in Preferences.
enum ThemeChoice {
    static let key = "appearance.theme"
    static let fallback = ThemeID.console

    static func id(for stored: String?) -> ThemeID {
        stored.flatMap(ThemeID.init(rawValue:)) ?? fallback
    }

    static func stored(in defaults: UserDefaults = .standard) -> ThemeID {
        id(for: defaults.string(forKey: key))
    }

    /// The theme was named on the command line (`-appearance.theme console`). A launch argument
    /// outranks the stored choice for the whole run, so choosing a theme changes nothing until
    /// the app is opened without it.
    static var isFixedByLaunchArgument: Bool {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[key] != nil
    }

    static func select(_ id: ThemeID, in defaults: UserDefaults = .standard) {
        defaults.set(id.rawValue, forKey: key)
    }
}

/// Puts the chosen theme in the environment and follows the choice while the app runs.
struct AppThemeRoot: ViewModifier {
    @AppStorage(ThemeChoice.key) private var stored = ThemeChoice.fallback.rawValue

    func body(content: Content) -> some View {
        content.environment(\.theme, .named(ThemeChoice.id(for: stored)))
    }
}

extension View {
    /// Applies the persisted theme choice to everything below.
    func appTheme() -> some View { modifier(AppThemeRoot()) }
}

// MARK: - Inks

/// A colour role of the current theme. Increase Contrast swaps the secondary ink for
/// `strongSecondary` and every rule or outline role for `strongBorder`, as tokens.json
/// "appearanceOverrides" requires.
struct ThemeInk: ShapeStyle {
    let role: KeyPath<Theme, ThemeColor> & Sendable

    func resolve(in environment: EnvironmentValues) -> Color {
        let theme = environment.theme
        if environment.usesStrongContrast {
            if role == \Theme.color.secondary { return theme.contrast.strongSecondary.color }
            if Self.isOutline(role) { return theme.contrast.strongBorder.color }
        }
        return theme[keyPath: role].color
    }

    static func isOutline(_ role: KeyPath<Theme, ThemeColor>) -> Bool {
        role == \Theme.color.hair || role == \Theme.color.border || role == \Theme.surface.panelEdge
            || role == \Theme.surface.markEdge || role == \Theme.surface.unselectedEdge
            || role == \Theme.surface.fieldEdge || role == \Theme.surface.controlEdge || role == \Theme.surface.tagEdge
            || role == \Theme.wall.groupEdge
    }
}

extension ShapeStyle where Self == ThemeInk {
    static func theme(_ role: KeyPath<Theme, ThemeColor> & Sendable) -> ThemeInk { ThemeInk(role: role) }
}

extension Tone {
    /// The tone's colour role in a theme.
    var role: KeyPath<Theme, ThemeColor> & Sendable {
        switch self {
        case .working: \Theme.color.working
        case .attention: \Theme.color.attention
        case .failure: \Theme.color.failure
        case .focus: \Theme.color.focus
        case .neutral: \Theme.color.secondary
        }
    }
}

// MARK: - Type

extension View {
    /// Sets a type role: face, size, weight, tracking and case.
    func themeType(_ font: ThemeFont) -> some View {
        self.font(font.font).tracking(font.tracking).textCase(font.uppercase ? .uppercase : nil)
    }
}

extension Theme {
    /// The outline of a button or filter: a capsule or a rectangle with the control radius.
    var controlShape: RoundedRectangle {
        switch style.buttonShape {
        case .capsule: RoundedRectangle(cornerRadius: 999, style: .circular)
        case .rectangle: RoundedRectangle(cornerRadius: radius.control, style: .continuous)
        }
    }
}
