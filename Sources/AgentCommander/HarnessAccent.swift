import SwiftUI
import AppKit

// MARK: - Tokens (design/system/tokens.json → color.harness.*)

enum HarnessAccentTokens {
    static let claude: UInt32 = 0xD97757              // color.harness.claude
    static let codex: UInt32 = 0x629FFF               // color.harness.codex
    static let mcp: UInt32 = 0xB596EF                 // color.harness.mcp
    /// Reserve the attention glow color when spacing harness colors.
    static let attentionReference: UInt32 = 0xF1C587  // color.attention
    static let avatarBase: UInt32 = 0x1C1D24          // Palette.chrome
    static let minSeparation = 0.06                   // OKLab distance between any two active accents
    static let attentionInset: CGFloat = 2            // amber cue sits inside the brand edge
    static let minimumChoices = 8
    static let vividCount = 8                         // first N swatches are preferred for defaults
    /// color.harness.swatch.* — none sits within minSeparation of a built-in default or amber.
    static let swatches: [(name: String, hex: UInt32)] = [
        ("Rose", 0xFB7185), ("Lime", 0xA3E635), ("Mint", 0x4ADE80), ("Teal", 0x2DD4BF),
        ("Cyan", 0x22D3EE), ("Sky", 0x38BDF8), ("Fuchsia", 0xE879F9), ("Pink", 0xF472B6),
        ("Ice", 0xBAE6FD), ("Sage", 0xBBF7D0), ("Blush", 0xFBCFE8),
    ]
}

// MARK: - Harness identity

enum HarnessName {
    /// Trim, collapse whitespace, case/width fold. Exact-match only; never substring.
    nonisolated static func normalize(_ raw: String?) -> String {
        (raw ?? "").precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

extension AgentClient {
    /// Only exact aliases identify a built-in harness.
    init(_ raw: String?) {
        switch HarnessName.normalize(raw) {
        case "claude", "claude-code", "claude code": self = .claude
        case "codex", "codex cli", "openai codex": self = .codex
        case "mcp", "mcp client", "generic mcp", "generic mcp client": self = .mcp
        default: self = .other((raw ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " "))
        }
    }

    /// Live mapper: nil/blank worker client falls back to the run's client.
    init(_ raw: String?, fallback: String?) {
        self.init(HarnessName.normalize(raw).isEmpty ? fallback : raw)
    }

    /// Normalized persistence/allocation scope. Custom names can never alias a built-in.
    nonisolated var harnessKey: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .mcp: "mcp"
        case .other(let name): "custom:" + HarnessName.normalize(name)
        }
    }
}

// MARK: - Accent value

struct HarnessAccent: Hashable, Sendable {
    let hex: UInt32
    init(_ hex: UInt32) { self.hex = hex & 0xFFFFFF }

    var color: Color { mixed(with: hex, 0) }
    func edge(strong: Bool = false) -> Color { strong ? mixed(with: 0xFFFFFF, 0.25) : color }
    func ink(strong: Bool = false) -> Color { edge(strong: strong) }
    func fill(opaque: Bool = false) -> Color {
        opaque ? HarnessAccent(HarnessAccentTokens.avatarBase).mixed(with: hex, 0.18) : color.opacity(0.16)
    }
    var avatarEdge: Color { color.opacity(0.42) }

    /// sRGB blend; `share` is the amount of `other`.
    func mixed(with other: UInt32, _ share: Double) -> Color {
        func channel(_ shift: UInt32) -> Double {
            (Double((hex >> shift) & 0xFF) * (1 - share) + Double((other >> shift) & 0xFF) * share) / 255
        }
        return Color(.sRGB, red: channel(16), green: channel(8), blue: channel(0), opacity: 1)
    }
}

struct HarnessAccentChoice: Identifiable {
    let hex: UInt32
    let name: String
    var id: UInt32 { hex }
}

// MARK: - OKLab (perceptual spacing)

private struct OKLab {
    var l: Double, a: Double, b: Double

    init(hex: UInt32) {
        func linear(_ shift: UInt32) -> Double {
            let c = Double((hex >> shift) & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = linear(16), g = linear(8), bl = linear(0)
        let lc = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl)
        let mc = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl)
        let sc = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl)
        l = 0.2104542553 * lc + 0.7936177850 * mc - 0.0040720468 * sc
        a = 1.9779984951 * lc - 2.4285922050 * mc + 0.4505937099 * sc
        b = 0.0259040371 * lc + 0.7827717662 * mc - 0.8086757660 * sc
    }

    init(l: Double, chroma: Double, hueDegrees: Double) {
        let h = hueDegrees * .pi / 180
        self.l = l; a = chroma * cos(h); b = chroma * sin(h)
    }

    var hex: UInt32 {
        func cube(_ x: Double) -> Double { x * x * x }
        let lc = cube(l + 0.3963377774 * a + 0.2158037573 * b)
        let mc = cube(l - 0.1055613458 * a - 0.0638541728 * b)
        let sc = cube(l - 0.0894841775 * a - 1.2914855480 * b)
        func encode(_ linear: Double) -> UInt32 {
            let c = min(max(linear, 0), 1)
            return UInt32(((c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055) * 255).rounded())
        }
        return encode(4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc) << 16
            | encode(-1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc) << 8
            | encode(-0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc)
    }

    func distance(to o: OKLab) -> Double {
        ((l - o.l) * (l - o.l) + (a - o.a) * (a - o.a) + (b - o.b) * (b - o.b)).squareRoot()
    }
}

// MARK: - Store

@MainActor @Observable
final class HarnessAccentStore {
    static let shared = HarnessAccentStore()

    /// One UserDefaults key per normalized harness: "<prefix><harnessKey>" → "#RRGGBB".
    static let overridePrefix = "AgentCommander.harnessAccent.override."
    /// Allocated defaults for custom harnesses, persisted so they are stable across relaunch.
    static let assignedPrefix = "AgentCommander.harnessAccent.assigned."

    private static let builtins: [String: UInt32] = [
        "claude": HarnessAccentTokens.claude, "codex": HarnessAccentTokens.codex, "mcp": HarnessAccentTokens.mcp,
    ]

    private let defaults: UserDefaults
    private(set) var overrides: [String: UInt32] = [:]
    private(set) var assigned: [String: UInt32] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Unreadable values are skipped, never deleted.
        for (key, value) in defaults.dictionaryRepresentation() {
            guard let text = value as? String, let hex = Self.parse(text) else { continue }
            if key.hasPrefix(Self.overridePrefix) {
                overrides[String(key.dropFirst(Self.overridePrefix.count))] = hex
            } else if key.hasPrefix(Self.assignedPrefix) {
                assigned[String(key.dropFirst(Self.assignedPrefix.count))] = hex
            }
        }
    }

    // Reads (pure; safe during view update)

    func accent(for client: AgentClient) -> HarnessAccent {
        overrides[client.harnessKey].map(HarnessAccent.init) ?? defaultAccent(for: client)
    }

    func defaultAccent(for client: AgentClient) -> HarnessAccent {
        let key = client.harnessKey
        if let hex = Self.builtins[key] ?? assigned[key] { return HarnessAccent(hex) }
        // Not registered yet: same value register(_:) will store.
        return HarnessAccent(Self.pick(seed: Self.fnv1a(key), avoiding: reserved(excluding: key)))
    }

    func overrideHex(for client: AgentClient) -> UInt32? { overrides[client.harnessKey] }

    /// Swatches that cannot collide with any other harness's active or default colour.
    func choices(for client: AgentClient) -> [HarnessAccentChoice] {
        let key = client.harnessKey
        var avoid = reserved(excluding: key) + [defaultAccent(for: client).hex]
        var out = HarnessAccentTokens.swatches
            .filter { Self.gap($0.hex, avoid) >= HarnessAccentTokens.minSeparation }
            .map { HarnessAccentChoice(hex: $0.hex, name: $0.name) }
        avoid += HarnessAccentTokens.swatches.map(\.hex)
        var n: UInt64 = 1
        while out.count < HarnessAccentTokens.minimumChoices {   // top up so an override is always possible
            let hex = Self.pick(seed: n &* 0x9E37_79B9_7F4A_7C15, avoiding: avoid)
            avoid.append(hex); n += 1
            out.append(HarnessAccentChoice(hex: hex, name: Self.string(hex)))
        }
        if let current = overrides[key], !out.contains(where: { $0.hex == current }) {
            out.insert(HarnessAccentChoice(hex: current, name: Self.string(current)), at: 0)
        }
        return out
    }

    // Writes (call from lifecycle/actions only)

    /// Gives a custom harness its stable default. No-op for built-ins and known harnesses.
    func register(_ client: AgentClient) {
        let key = client.harnessKey
        guard Self.builtins[key] == nil, assigned[key] == nil else { return }
        let hex = Self.pick(seed: Self.fnv1a(key), avoiding: reserved(excluding: key))
        assigned[key] = hex
        defaults.set(Self.string(hex), forKey: Self.assignedPrefix + key)
    }

    /// `nil` restores the default. Touches only this harness's key.
    func setOverride(_ hex: UInt32?, for client: AgentClient) {
        let key = client.harnessKey
        guard let hex else {
            overrides[key] = nil
            defaults.removeObject(forKey: Self.overridePrefix + key)
            return
        }
        let taken = reserved(excluding: key)
        guard !taken.contains(hex) else { return }
        // On a crowded palette, the menu offers the most widely spaced available colors.
        guard Self.gap(hex, taken) >= HarnessAccentTokens.minSeparation
            || choices(for: client).contains(where: { $0.hex == hex }) else { return }
        overrides[key] = hex
        defaults.set(Self.string(hex), forKey: Self.overridePrefix + key)
    }

    // Allocation

    /// Every colour another harness shows or could return to, plus attention amber.
    private func reserved(excluding key: String) -> [UInt32] {
        var out = [HarnessAccentTokens.attentionReference]
        for source in [Self.builtins, assigned, overrides] {
            for (other, hex) in source where other != key { out.append(hex) }
        }
        return out
    }

    private static func gap(_ hex: UInt32, _ others: [UInt32]) -> Double {
        let point = OKLab(hex: hex)
        return others.map { point.distance(to: OKLab(hex: $0)) }.min() ?? .infinity
    }

    /// First candidate clear of everything reserved; otherwise the one furthest from it.
    private static func pick(seed: UInt64, avoiding reserved: [UInt32]) -> UInt32 {
        var best: (hex: UInt32, gap: Double) = (HarnessAccentTokens.swatches[0].hex, -1)
        for hex in candidates(seed) {
            let distance = gap(hex, reserved)
            if distance >= HarnessAccentTokens.minSeparation { return hex }
            if distance > best.gap { best = (hex, distance) }
        }
        return best.hex
    }

    /// Named palette rotated by the seed, then golden-angle hues over three lightness tiers.
    private static func candidates(_ seed: UInt64) -> [UInt32] {
        let named = HarnessAccentTokens.swatches.map(\.hex)
        let vivid = HarnessAccentTokens.vividCount
        let start = Int(seed % UInt64(vivid))
        var out = (0..<vivid).map { named[(start + $0) % vivid] } + named[vivid...]
        let tiers: [(l: Double, c: Double)] = [(0.78, 0.12), (0.88, 0.07), (0.68, 0.13)]
        let hue = Double(seed % 360)
        for i in 0..<96 {
            let tier = tiers[(i / 12) % 3]
            out.append(OKLab(l: tier.l, chroma: tier.c, hueDegrees: hue + Double(i) * 137.508).hex)
        }
        return out
    }

    /// Deterministic across launches (no hashValue).
    private static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 { hash ^= UInt64(byte); hash &*= 0x100_0000_01B3 }
        return hash
    }

    static func string(_ hex: UInt32) -> String { String(format: "#%06X", hex & 0xFFFFFF) }

    private static func parse(_ text: String) -> UInt32? {
        guard text.count == 7, text.hasPrefix("#") else { return nil }
        return UInt32(text.dropFirst(), radix: 16)
    }
}

// MARK: - Surfaces

extension HarnessAccent {
    /// Opaque title-bar fill: accent mixed into chrome #1C1D24.
    /// Accent share is capped by the accent's luminance, so bright hues stay dark enough for text.
    func headerFill(strongContrast: Bool = false) -> Color {
        let c = [hex >> 16, hex >> 8, hex].map { v -> Double in
            let s = Double(v & 0xFF) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
        let t = strongContrast ? min(0.22, 0.08 / luminance) : min(0.30, 0.12 / luminance)
        return mixed(with: HarnessAccentTokens.avatarBase, 1 - t)
    }
}

struct HarnessHeaderFill: ViewModifier {
    let client: AgentClient
    @Environment(\.usesStrongContrast) private var strong

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                HarnessAccentStore.shared.accent(for: client).headerFill(strongContrast: strong)
                LinearGradient(colors: [Color.white.opacity(0.045), .clear],
                               startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

extension View {
    func harnessHeaderFill(_ client: AgentClient) -> some View {
        modifier(HarnessHeaderFill(client: client))
    }
}

private struct HarnessRegistration: ViewModifier {
    let client: AgentClient
    func body(content: Content) -> some View {
        content
            .onAppear { HarnessAccentStore.shared.register(client) }
            .onChange(of: client) { _, new in HarnessAccentStore.shared.register(new) }
    }
}

private struct HarnessConsoleSurface: ViewModifier {
    let client: AgentClient
    var attention = false
    var raised = true
    @Environment(\.usesStrongContrast) private var usesStrongContrast

    func body(content: Content) -> some View {
        let edge = HarnessAccentStore.shared.accent(for: client).edge(strong: usesStrongContrast)
        content
            .consoleSurface(edge: edge, raised: raised)
            .attentionGlow(attention)                       // keeps the animated exterior glow
            .overlay {
                if attention {
                    Group {
                        Rectangle().strokeBorder(edge, lineWidth: 1)   // brand edge back on top of the glow's amber stroke
                        Rectangle().inset(by: HarnessAccentTokens.attentionInset)
                            .strokeBorder(Palette.attentionEdge, lineWidth: 1)
                    }
                    .allowsHitTesting(false)
                }
            }
            .modifier(HarnessRegistration(client: client))
    }
}

private struct HarnessAccentOutline: ViewModifier {
    let client: AgentClient
    var cornerRadius: CGFloat = 0
    @Environment(\.usesStrongContrast) private var usesStrongContrast

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(HarnessAccentStore.shared.accent(for: client).edge(strong: usesStrongContrast), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .modifier(HarnessRegistration(client: client))
    }
}

extension View {
    /// Square console surface with the harness edge; amber shows as inset line + outer glow.
    func harnessConsoleSurface(_ client: AgentClient, attention: Bool = false, raised: Bool = true) -> some View {
        modifier(HarnessConsoleSurface(client: client, attention: attention, raised: raised))
    }

    /// Harness edge only, for wells that draw their own background.
    func harnessAccentOutline(_ client: AgentClient, cornerRadius: CGFloat = 0) -> some View {
        modifier(HarnessAccentOutline(client: client, cornerRadius: cornerRadius))
    }

    /// Amber inset cue for surfaces that keep their own (rounded) brand edge.
    func harnessAttentionInset(_ active: Bool, cornerRadius: CGFloat = 0) -> some View {
        overlay {
            if active {
                RoundedRectangle(cornerRadius: max(0, cornerRadius - HarnessAccentTokens.attentionInset))
                    .inset(by: HarnessAccentTokens.attentionInset)
                    .strokeBorder(Palette.attentionEdge, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }

    func registersHarness(_ client: AgentClient) -> some View { modifier(HarnessRegistration(client: client)) }
}

// MARK: - Override menu

/// Submenu for the existing display icon menu.
struct HarnessAccentMenu: View {
    let client: AgentClient

    var body: some View {
        let store = HarnessAccentStore.shared
        Menu("Accent for \(client.displayName)") {
            Picker("Accent", selection: Binding(
                get: { store.overrideHex(for: client) },
                set: { store.setOverride($0, for: client) }
            )) {
                row("Default", store.defaultAccent(for: client).hex).tag(UInt32?.none)
                ForEach(store.choices(for: client)) { choice in
                    row(choice.name, choice.hex).tag(UInt32?.some(choice.hex))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .registersHarness(client)
    }

    private func row(_ name: String, _ hex: UInt32) -> some View {
        Label { Text(name) } icon: { Image(nsImage: Self.swatch(hex)) }
    }

    /// Non-template bitmap so the menu shows the true colour.
    private static func swatch(_ hex: UInt32) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 24, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return NSImage(size: size) }
        context.setFillColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                             blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        context.fill(CGRect(x: 2, y: 2, width: 20, height: 20))
        guard let image = context.makeImage() else { return NSImage(size: size) }
        return NSImage(cgImage: image, size: size)
    }
}
