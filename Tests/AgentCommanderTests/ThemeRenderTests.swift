import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// Headless pictures of the Preferences, Hosts, All agents and History pages in both themes, drawn
// from the design-preview samples. Skipped unless THEME_RENDER_DIR names a folder for the PNG files:
//
//     THEME_RENDER_DIR=design/demos/main-window-1 swift test --filter ThemeRender
//
// Each page is drawn alone on the theme's opaque canvas, without the window's navigation and
// toolbar. Nothing here opens a window on screen, touches the running app or reads user defaults.

let themeRenderDirectory = ProcessInfo.processInfo.environment["THEME_RENDER_DIR"]

@MainActor @Suite struct ThemeRenderTests {
    static let size = CGSize(width: 1340, height: 1080)

    static func fileName(_ page: String, _ theme: Theme) -> String {
        "\(page)-\(theme.id == .blackGlass ? "black-glass" : "console").png"
    }

    static func write(_ page: some View, _ name: String, theme: Theme, to folder: URL) async throws {
        let root = ThemeCanvas { page }
            .frame(width: size.width, height: size.height)
            .environment(\.theme, theme)
            .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
        }
        let bounds = host.bounds
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: bounds))
        host.cacheDisplay(in: bounds, to: image)
        let png = try #require(image.representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent(fileName(name, theme)))
        window.contentView = nil
    }

    @Test(.enabled(if: themeRenderDirectory != nil)) func drawsFourPagesInBothThemes() async throws {
        let folder = URL(fileURLWithPath: try #require(themeRenderDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        for id in ThemeID.allCases {
            let theme = Theme.named(id)
            try await Self.write(
                PreferencesPage(projectName: "Relay", retention: "30 days",
                                retentionOptions: ["7 days", "30 days", "90 days", "1 year"],
                                showsSystemAppearance: false, presentation: .drawer, choosePresentation: { _ in }),
                "preferences", theme: theme, to: folder)
            try await Self.write(
                HostsPage(subtitle: "Local and SSH execution environments for Relay.", hosts: PreviewSample.hosts,
                          selection: "build-01", capabilities: PreviewSample.hostCapabilities, configPath: "~/.ssh/config",
                          policyTitle: "Run disconnect policy",
                          policyDetail: "Retry policy can finish current assignments on build-01. Further delegation waits for reconnect.",
                          policyStatus: "Hold delegation", enroll: {}, recover: { _ in }),
                "hosts", theme: theme, to: folder)
            try await Self.write(
                AllAgentsPage(agents: PreviewSample.agents(tick: 0), open: { _ in }, startRun: {}, saveView: {}),
                "all-agents", theme: theme, to: folder)
            try await Self.write(
                HistoryPage(kicker: "RELAY / HISTORY",
                            subtitle: "15:02 · Search the Relay project’s recorded output, including conversations owned by another coordinator.",
                            query: "timeout budget", project: "Relay", matches: PreviewSample.transcriptMatches,
                            sharingNote: "Project history shared across its coordinators.", retention: "Retention · 30 days",
                            openWorker: { _ in }, openRun: { _ in }),
                "history", theme: theme, to: folder)
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(Self.fileName("history", theme)).path))
        }
    }
}
