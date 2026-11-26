import AppKit
import SwiftUI

// Agent Commander > Restart Agent Commander, above Quit.
//
// The running copy holds the single-instance lease, so a second copy opened while it is alive would
// hand off to it and exit. Restart starts a small detached helper that waits for this process to
// end and then opens the same bundle through Launch Services, then quits normally. Running
// assignments survive, as they do for Quit.

enum AppRestart {
    /// The helper's command line: waits for `pid` to exit, then opens `bundlePath`.
    static func relaunchCommand(pid: Int32, bundlePath: String) -> (executable: String, arguments: [String]) {
        let script = #"while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open "$2""#
        return ("/bin/sh", ["-c", script, "agent-commander-restart", String(pid), bundlePath])
    }

    /// Starts the helper, then quits. If the helper can't start, the app stays open.
    @MainActor
    static func restart(bundle: Bundle = .main) {
        let command = relaunchCommand(pid: ProcessInfo.processInfo.processIdentifier,
                                      bundlePath: bundle.bundleURL.path)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: command.executable)
        helper.arguments = command.arguments
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
        } catch {
            NSSound.beep()
            return
        }
        NSApp.terminate(nil)
    }
}

/// The app menu's Restart item, placed in Quit's group so it sits directly above Quit.
struct AppRestartCommands: Commands {
    var body: some Commands {
        CommandGroup(before: .appTermination) {
            Button("Restart Agent Commander") { AppRestart.restart() }
        }
    }
}
