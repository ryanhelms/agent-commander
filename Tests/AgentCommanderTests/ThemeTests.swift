import Foundation
import SwiftUI
import Testing
@testable import AgentCommander

// The theme layer's contract:
//   1. Both themes in ThemeTokens.swift hold exactly the values of design/system/tokens.json "themes".
//   2. The console theme's base roles are DESIGN.md section 2.
//   3. The console, the terminal and the pretty view never read a Theme, nor a component that does.
//   4. The choice persists under `appearance.theme` and falls back to black glass.

@Suite struct ThemeTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    // MARK: Swift side

    static func number(_ value: Double) -> String { String(format: "%g", value) }

    static func canonical(_ color: ThemeColor) -> String {
        String(format: "#%06X", color.hex) + (color.opacity == 1 ? "" : "@" + number(color.opacity))
    }

    static func canonical(_ fill: ThemeFill) -> String {
        fill.axis == .flat ? canonical(fill.stops[0]) : "\(fill.axis.rawValue): " + fill.stops.map { canonical($0) }.joined(separator: " > ")
    }

    static func canonical(_ font: ThemeFont) -> String {
        "\(font.face.rawValue) \(number(font.size)) \(font.weight.rawValue) tracking \(number(font.tracking))\(font.uppercase ? " upper" : "")"
    }

    /// Every leaf of a token value, keyed by its path.
    static func flatten(_ value: Any, path: String, into result: inout [String: String]) {
        switch value {
        case let color as ThemeColor: result[path] = canonical(color)
        case let fill as ThemeFill: result[path] = canonical(fill)
        case let font as ThemeFont: result[path] = canonical(font)
        case let text as String: result[path] = text
        case let number as CGFloat: result[path] = Self.number(number)
        case let number as Double: result[path] = Self.number(number)
        case let raw as any RawRepresentable: result[path] = "\(raw.rawValue)"
        default:
            for child in Mirror(reflecting: value).children {
                guard let label = child.label else { continue }
                flatten(child.value, path: path.isEmpty ? label : "\(path).\(label)", into: &result)
            }
        }
    }

    static func tokens(of theme: Theme) -> [String: String] {
        var result: [String: String] = [:]
        flatten(theme, path: "", into: &result)
        result["id"] = nil
        return result
    }

    // MARK: tokens.json side

    static func themesJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent("design/system/tokens.json"))
        let file = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(file["themes"] as? [String: Any])
    }

    struct TokenError: Error, CustomStringConvertible { let description: String }

    /// "#RRGGBB", "#RRGGBB@0.5", "role" or "role@0.5", resolved against the theme's colour roles.
    static func color(_ text: String, roles: [String: Any]) throws -> String? {
        let parts = text.split(separator: "@", maxSplits: 1).map(String.init)
        var base = parts[0]
        if !base.hasPrefix("#") {
            guard let role = roles[base] as? String else { return nil }
            guard role.hasPrefix("#"), !role.contains("@") || parts.count == 1 else {
                throw TokenError(description: "\(text): a role with its own opacity cannot take another")
            }
            if parts.count == 1 { return role.uppercased().replacingOccurrences(of: "@1", with: "") }
            base = String(role.split(separator: "@")[0])
        }
        let opacity = parts.count > 1 ? try #require(Double(parts[1])) : 1
        return base.uppercased() + (opacity == 1 ? "" : "@" + number(opacity))
    }

    static func font(_ entry: [String: Any]) throws -> String {
        let face = try #require(entry["face"] as? String)
        let size = try #require(entry["size"] as? Double)
        let weight = try #require(entry["weight"] as? String)
        let tracking = entry["tracking"] as? Double ?? 0
        return "\(face) \(number(size)) \(weight) tracking \(number(tracking))\(entry["case"] as? String == "upper" ? " upper" : "")"
    }

    static func flattenJSON(_ value: Any, path: String, theme: [String: Any], into result: inout [String: String]) throws {
        let roles = theme["color"] as? [String: Any] ?? [:]
        let type = theme["type"] as? [String: Any] ?? [:]
        if let entry = value as? [String: Any] {
            if entry["face"] != nil {
                result[path] = try font(entry)
            } else if let stops = entry["stops"] as? [String] {
                let axis = try #require(entry["axis"] as? String)
                result[path] = "\(axis): " + (try stops.map { try #require(try color($0, roles: roles)) }).joined(separator: " > ")
            } else {
                for (key, child) in entry {
                    try flattenJSON(child, path: path.isEmpty ? key : "\(path).\(key)", theme: theme, into: &result)
                }
            }
        } else if let text = value as? String {
            if path.hasPrefix("pageType."), let alias = type[text] as? [String: Any] {
                result[path] = try font(alias)
            } else if path != "name", !path.hasPrefix("style."), path != "material.window", path != "motion.curve",
                      let resolved = try color(text, roles: roles) {
                result[path] = resolved
            } else {
                result[path] = text
            }
        } else if let number = value as? Double {
            result[path] = Self.number(number)
        }
    }

    static func tokens(ofJSON theme: [String: Any]) throws -> [String: String] {
        var result: [String: String] = [:]
        try flattenJSON(theme, path: "", theme: theme, into: &result)
        result["source"] = nil
        return result
    }

    // MARK: Tests

    @Test(arguments: ThemeID.allCases) func themeMatchesTokensFile(_ id: ThemeID) throws {
        let expected = try Self.tokens(ofJSON: try #require(try Self.themesJSON()[id.rawValue] as? [String: Any]))
        let actual = Self.tokens(of: .named(id))
        #expect(Set(actual.keys) == Set(expected.keys),
                "roles differ: \(Set(actual.keys).symmetricDifference(expected.keys).sorted())")
        for (key, value) in expected.sorted(by: { $0.key < $1.key }) {
            #expect(actual[key] == value, "\(id.rawValue).\(key)")
        }
        #expect(actual.count > 80)
    }

    @Test func tokensFileNamesTheDefaultAndTheStorageKey() throws {
        let themes = try Self.themesJSON()
        #expect(themes["default"] as? String == ThemeChoice.fallback.rawValue)
        #expect(themes["storageKey"] as? String == ThemeChoice.key)
        #expect(Set(ThemeID.allCases.map(\.rawValue)).isSubset(of: Set(themes.keys)))
    }

    @Test func bothThemesDefineTheSameRoles() {
        #expect(Set(Self.tokens(of: .blackGlass).keys) == Set(Self.tokens(of: .console).keys))
    }

    /// DESIGN.md section 2, spelled out so a change to either file is noticed.
    @Test func consoleThemeIsTheDesignDocument() {
        let tokens = Self.tokens(of: .console)
        let expected: [String: String] = [
            "color.window": "#090A0D", "color.panel": "#14151A", "color.well": "#0B0C10", "color.hair": "#26282F",
            "color.border": "#383B44", "color.foreground": "#F5F5F9", "color.secondary": "#B7BAC6",
            "color.focus": "#B5D6FF", "color.working": "#A8E0C0", "color.attention": "#F1C587",
            "color.failure": "#EC9B92", "color.selection": "#283344", "color.onAccent": "#101825",
            "radius.tile": "2", "radius.control": "2", "radius.chip": "1",
            "line.hairline": "1", "line.selectedMarker": "2", "line.focusedField": "1.5",
            "type.title": "system 14 semibold tracking 0", "type.name": "system 13 medium tracking 0",
            "type.body": "system 13 regular tracking 0", "type.sub": "system 11 regular tracking 0",
            "type.heading": "mono 11.5 semibold tracking 0", "type.state": "mono 10.5 semibold tracking 0",
            "type.data": "mono 11 medium tracking 0", "type.mono": "mono 11 regular tracking 0",
            "type.label": "mono 9.5 semibold tracking 0", "type.fingerprint": "mono 10.5 regular tracking 0",
            "type.figure": "mono 14 semibold tracking 0",
            "space.sectionInset": "14", "space.bandTop": "10", "space.bandBottom": "12", "space.sectionGap": "18",
            "space.controlHeight": "24", "space.controlHeightLarge": "28", "space.fieldHeight": "30",
            "space.rowIcon": "28", "space.tabHeight": "34", "space.chipHeightMin": "16", "space.chipHeightMax": "18",
            "motion.fast": "0.1", "motion.standard": "0.18", "motion.slow": "0.25", "motion.pulse": "1.4",
            "motion.travel": "6", "motion.curve": "easeOut",
            "material.window": "opaque", "material.windowFill": "#090A0D",
            "surface.panelShadow.opacity": "0",
        ]
        for (key, value) in expected { #expect(tokens[key] == value, "console.\(key)") }
    }

    /// Black glass keeps the base values DesignTokens.swift already holds.
    @Test func blackGlassKeepsTheBasePalette() {
        let theme = Theme.blackGlass
        #expect(theme.color.window.color == Palette.window)
        #expect(theme.color.panel.color == Palette.panel)
        #expect(theme.color.well.color == Palette.well)
        #expect(theme.color.border.color == Palette.border)
        #expect(theme.color.foreground.color == Palette.foreground)
        #expect(theme.color.secondary.color == Palette.secondary)
        #expect(theme.color.focus.color == Palette.focus)
        #expect(theme.contrast.strongSecondary.color == Palette.strongSecondary)
        #expect(theme.contrast.strongBorder.color == Palette.strongBorder)
        #expect(theme.material.windowFill.color == Palette.opaqueChrome)
        #expect(theme.radius.tile == Radius.tile)
        #expect(theme.radius.control == Radius.field)
        #expect(theme.space.pageInset == Metric.sheetInset)
        #expect(theme.space.fieldHeight == Metric.fieldHeight)
        #expect(theme.material.window == .glass)
    }

    @Test func increaseContrastSwapsSecondaryInkAndOutlines() {
        for id in ThemeID.allCases {
            var environment = EnvironmentValues()
            environment.theme = .named(id)
            let theme = environment.theme
            #expect(ThemeInk(role: \.color.secondary).resolve(in: environment) == theme.color.secondary.color)
            #expect(ThemeInk(role: \.color.hair).resolve(in: environment) == theme.color.hair.color)
            environment.increaseContrastOverride = true
            #expect(ThemeInk(role: \.color.secondary).resolve(in: environment) == theme.contrast.strongSecondary.color)
            #expect(ThemeInk(role: \.color.hair).resolve(in: environment) == theme.contrast.strongBorder.color)
            #expect(ThemeInk(role: \.surface.panelEdge).resolve(in: environment) == theme.contrast.strongBorder.color)
            #expect(ThemeInk(role: \.color.foreground).resolve(in: environment) == theme.color.foreground.color)
        }
    }

    @Test func themeChoicePersistsAndFallsBackToBlackGlass() throws {
        let suite = "theme-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ThemeChoice.key == "appearance.theme")
        #expect(ThemeChoice.stored(in: defaults) == .blackGlass)
        ThemeChoice.select(.console, in: defaults)
        #expect(defaults.string(forKey: "appearance.theme") == "console")
        #expect(ThemeChoice.stored(in: defaults) == .console)
        defaults.set("no-such-theme", forKey: ThemeChoice.key)
        #expect(ThemeChoice.stored(in: defaults) == .blackGlass)
        #expect(EnvironmentValues().theme == .blackGlass)
    }

    // MARK: Console exemption

    /// The console, terminal and pretty view, their shell and their controls.
    static func isExempt(_ file: String) -> Bool {
        let prefixes = ["NativeTerminal", "Console", "Conversation", "ActivityStory", "CommanderActivity", "FollowUp"]
        let names = ["FocusedPrettyConsole.swift", "HarnessAccent.swift", "RecordFieldRows.swift",
                     "InterruptReceipt.swift", "ClaudeProgress.swift"]
        return prefixes.contains { file.hasPrefix($0) } || names.contains(file)
    }

    @Test func consoleTerminalAndPrettyViewNeverReadTheTheme() throws {
        let sources = Self.root.appendingPathComponent("Sources/AgentCommander")
        let files = try FileManager.default.contentsOfDirectory(atPath: sources.path).filter { $0.hasSuffix(".swift") }
        let exempt = files.filter(Self.isExempt)
        #expect(exempt.count >= 15, "the exempt file list no longer matches the source tree")
        for required in ["NativeTerminalComponents.swift", "NativeTerminalViewer.swift", "NativeTerminalWell.swift",
                         "ConsoleDisplay.swift", "ConsoleSource.swift", "ConsoleRecordDetail.swift",
                         "ConsolePromptAttachments.swift", "FocusedPrettyConsole.swift", "HarnessAccent.swift",
                         "ConversationChunks.swift"] {
            #expect(exempt.contains(required), "\(required) is missing")
        }
        // The theme layer's own names, then every component that reads `\.theme`.
        let layer = #"(?<![A-Za-z0-9_])Theme[A-Za-z0-9_]*|\\\.theme\b|\.theme\(|\.(themePanel|themeField|themeType|themeSwitch|appTheme|filterChipFrame|selectionCard|inspectorCard)\("#
        let components = ["PageHeader", "SectionHeading", "MetaText", "IconTile", "ValueTag", "FilterChip", "SelectionCard",
                          "SearchField", "Callout", "SettingRow", "FactColumn", "PanelTitle", "MenuField", "InspectorCard",
                          "HighlightedText", "DataTable", "WorkspacePage", "TaskSheet", "CockpitShell", "WindowGlass",
                          "PresentationThumbnail", "PresentationChoiceCard", "ChoiceMark"]
        let pattern = try NSRegularExpression(pattern: layer + "|\\b(" + components.joined(separator: "|") + ")\\b")
        for file in exempt.sorted() {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = String(line)
                guard !code.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                let range = NSRange(code.startIndex..., in: code)
                if let match = pattern.firstMatch(in: code, range: range), let found = Range(match.range, in: code) {
                    Issue.record("\(file):\(index + 1) reads the theme layer: \(code[found])")
                }
            }
        }
    }

    /// Every file that does read a Theme is outside the exempt set, and the scan can see them.
    @Test func themeReadersAreOutsideTheExemptSet() throws {
        let sources = Self.root.appendingPathComponent("Sources/AgentCommander")
        let files = try FileManager.default.contentsOfDirectory(atPath: sources.path).filter { $0.hasSuffix(".swift") }
        let readers = try files.filter {
            try String(contentsOf: sources.appendingPathComponent($0), encoding: .utf8).contains("\\.theme")
        }
        #expect(readers.contains("WorkspaceMolecules.swift"))
        #expect(readers.contains("ThemeAtoms.swift"))
        #expect(readers.filter(Self.isExempt).isEmpty)
    }
}
