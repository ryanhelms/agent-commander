import AppKit
import SwiftUI
import WebKit

// Minimal native shell for the focused Claude console proof of concept.
// Build: swiftc -parse-as-library -framework WebKit main.swift
// Run:   <binary> http://127.0.0.1:<port>[/path]
//
// One resizable Terminal-style window: the standard title bar over a WKWebView that fills the
// rest. The title bar mirrors the page title. Navigation is limited to the origin given on the
// command line.

// MARK: - Launch argument

/// Scheme, host and port of the page the shell is allowed to show.
struct Origin: Equatable {
    let scheme: String
    let host: String
    let port: Int

    init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = url.port ?? (scheme == "https" ? 443 : 80)
    }
}

enum Launch {
    case page(URL, Origin)
    case invalid(String)

    static func fromArguments() -> Launch {
        let arguments = CommandLine.arguments
        guard arguments.count > 1 else {
            return .invalid("No address was given. Pass an http://127.0.0.1 URL as the first argument.")
        }
        let raw = arguments[1]
        guard let url = URL(string: raw), let origin = Origin(url),
              origin.scheme == "http", origin.host == "127.0.0.1" else {
            return .invalid("“\(raw)” is not an http://127.0.0.1 URL.")
        }
        return .page(url, origin)
    }
}

// MARK: - Web view

@MainActor
final class ConsoleBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var failure: String?
    /// The page's title, shown in the window's title bar as Terminal shows the running command.
    @Published var pageTitle = ""
    let webView: WKWebView
    private let home: URL
    private let origin: Origin
    private var titleObservation: NSKeyValueObservation?

    init(home: URL, origin: Origin) {
        self.home = home
        self.origin = origin

        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        super.init()

        titleObservation = webView.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
            Task { @MainActor in self?.pageTitle = view.title ?? "" }
        }

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = ShellColor.window
        // Avoids a white flash before the dark page paints.
        webView.setValue(false, forKey: "drawsBackground")
        webView.setAccessibilityLabel("Claude console")
        load()
    }

    func load() {
        failure = nil
        webView.load(URLRequest(url: home))
    }

    private func isAllowed(_ url: URL?) -> Bool {
        guard let url, let candidate = Origin(url) else { return false }
        return candidate == origin
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        isAllowed(navigationAction.request.url) ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        isAllowed(navigationResponse.response.url) ? .allow : .cancel
    }

    /// The console never opens other windows.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failure = "The console stopped unexpectedly."
    }

    private func report(_ error: Error) {
        let nsError = error as NSError
        // A cancelled load is this shell declining a navigation, or a reload replacing one.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
        failure = error.localizedDescription
    }
}

struct WebSurface: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - Views

enum ShellColor {
    static let window = NSColor(srgbRed: 0x09 / 255, green: 0x0A / 255, blue: 0x0D / 255, alpha: 1)
    static let attention = Color(red: 0xF1 / 255, green: 0xC5 / 255, blue: 0x87 / 255)
    static let secondary = Color(red: 0xB7 / 255, green: 0xBA / 255, blue: 0xC6 / 255)
}

struct NoticeView: View {
    let title: String
    let detail: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(ShellColor.attention)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 18, weight: .semibold))
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(ShellColor.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 440)
            if let retry {
                Button("Try again", action: retry).keyboardShortcut("r", modifiers: .command)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: ShellColor.window))
    }
}

struct ConsoleView: View {
    @ObservedObject var browser: ConsoleBrowser

    var body: some View {
        ZStack {
            WebSurface(webView: browser.webView)
            if let failure = browser.failure {
                NoticeView(title: "The console could not be loaded", detail: failure) { browser.load() }
            }
        }
        .navigationTitle(browser.pageTitle.isEmpty ? "Agent Commander" : browser.pageTitle)
    }
}

struct RootView: View {
    let launch: Launch
    @State private var browser: ConsoleBrowser?

    var body: some View {
        Group {
            switch launch {
            case .invalid(let reason):
                NoticeView(title: "Agent Commander console", detail: reason)
            case .page(let url, let origin):
                if let browser {
                    ConsoleView(browser: browser)
                } else {
                    Color(nsColor: ShellColor.window)
                        .onAppear { browser = ConsoleBrowser(home: url, origin: origin) }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 360)
        .background(WindowChrome())
        .preferredColorScheme(.dark)
    }
}

/// Keeps the standard macOS title bar, with its traffic lights and centered title, and gives it
/// the terminal's background so the bar and the screen read as one Terminal-style window.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = true
            window.styleMask.remove(.fullSizeContentView)
            window.backgroundColor = ShellColor.window
            window.appearance = NSAppearance(named: .darkAqua)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - App

final class ShellDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when the binary runs outside an app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ConsoleShellApp: App {
    @NSApplicationDelegateAdaptor(ShellDelegate.self) private var delegate
    private let launch = Launch.fromArguments()

    var body: some Scene {
        Window("Agent Commander", id: "console") {
            RootView(launch: launch)
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
