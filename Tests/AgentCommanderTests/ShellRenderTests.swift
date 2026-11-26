import AppKit
import SwiftUI
import Testing
@testable import AgentCommander

// Headless pictures of the three sidebar prototypes and the Needs you inbox in both themes, drawn
// from the design-preview samples. Skipped unless SHELL_RENDER_DIR names a folder for the PNG files:
//
//     SHELL_RENDER_DIR=design/demos/main-window-2 swift test --filter ShellRender
//
// Each picture is a whole window at 1440 x 900 points and one pixel per point: navigation, a drawn
// toolbar band and the canvas. Nothing here opens a window on screen, touches the running app or
// reads user defaults.

let shellRenderDirectory = ProcessInfo.processInfo.environment["SHELL_RENDER_DIR"]

@MainActor @Suite struct ShellRenderTests {
    static let size = CGSize(width: 1440, height: 900)

    static func fileName(_ page: String, _ theme: Theme) -> String {
        "\(page)-\(theme.id == .blackGlass ? "black-glass" : "console").png"
    }

    /// Draws a view at one pixel per point and writes it as a PNG.
    static func write(_ view: some View, _ name: String, theme: Theme, to folder: URL) async throws {
        let root = view
            .frame(width: size.width, height: size.height)
            .environment(\.theme, theme)
            .environment(\.reduceTransparencyOverride, true)
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
        let image = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        image.size = size
        host.cacheDisplay(in: host.bounds, to: image)
        let png = try #require(image.representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent(fileName(name, theme)))
        window.contentView = nil
    }

    /// One shell window: the scenario's sidebar with the given place selected.
    static func shell(_ scenario: DesignPreviewScenario, place: String) -> some View {
        ShellPreviewPage(store: PreviewStore(scenario: scenario), state: ShellPreviewState(selection: place), chrome: .drawn)
    }

    @Test(.enabled(if: shellRenderDirectory != nil)) func drawsTheShellInBothThemes() async throws {
        let folder = URL(fileURLWithPath: try #require(shellRenderDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        for id in ThemeID.allCases {
            let theme = Theme.named(id)
            try await Self.write(Self.shell(.shellA, place: "all-agents"), "shell-a", theme: theme, to: folder)
            try await Self.write(Self.shell(.shellB, place: "network.servers"), "shell-b", theme: theme, to: folder)
            try await Self.write(Self.shell(.shellC, place: "history"), "shell-c", theme: theme, to: folder)
            try await Self.write(Self.shell(.needsYou, place: "needs-you"), "needs-you", theme: theme, to: folder)
            try await Self.write(
                ThemeCanvas { NeedsYouPage(inbox: NeedsYouInbox(items: []), decide: { _, _ in }, open: { _ in }) },
                "needs-you-empty", theme: theme, to: folder)
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(Self.fileName("needs-you", theme)).path))
        }
    }

    /// The coordinator wall inside the shell lays out without a window. Kept out of the demo set.
    @Test(.enabled(if: shellRenderDirectory != nil && ProcessInfo.processInfo.environment["SHELL_RENDER_WALL"] != nil))
    func drawsTheWallInsideTheShell() async throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SHELL_RENDER_WALL"]), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        for id in ThemeID.allCases {
            try await Self.write(Self.shell(.shellA, place: "runs"), "shell-wall", theme: .named(id), to: folder)
        }
    }
}
