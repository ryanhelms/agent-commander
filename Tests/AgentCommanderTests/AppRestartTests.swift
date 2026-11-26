import Foundation
import Testing
@testable import AgentCommander

// Restart Agent Commander: the helper waits for the old process to end, then opens the same bundle.

@Suite struct AppRestartTests {
    @Test func helperWaitsForTheOldProcessThenOpensTheBundle() throws {
        let command = AppRestart.relaunchCommand(pid: 4242, bundlePath: "/tmp/Agent Commander.app")
        #expect(command.executable == "/bin/sh")
        #expect(command.arguments.count == 5)
        #expect(command.arguments[0] == "-c")
        let script = command.arguments[1]
        let wait = try #require(script.range(of: #"/bin/kill -0 "$1""#))
        let open = try #require(script.range(of: #"/usr/bin/open "$2""#))
        #expect(wait.upperBound < open.lowerBound)
        // The pid and the path travel as arguments, never spliced into the script.
        #expect(command.arguments[3] == "4242")
        #expect(command.arguments[4] == "/tmp/Agent Commander.app")
        #expect(!script.contains("Agent Commander.app"))
    }

    @Test func helperOpensTheBundleOnlyAfterThePidExits() throws {
        // A detached sleeper stands in for the app. It is not this process's child, so once it exits
        // the system reaps it and no zombie keeps `kill -0` true.
        let starter = Process()
        starter.executableURL = URL(fileURLWithPath: "/bin/sh")
        starter.arguments = ["-c", "/bin/sleep 0.5 >/dev/null 2>&1 & echo $!"]
        let pidPipe = Pipe()
        starter.standardOutput = pidPipe
        try starter.run()
        starter.waitUntilExit()
        let pidText = String(decoding: pidPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let pid = try #require(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        let started = Date()
        let command = AppRestart.relaunchCommand(pid: pid, bundlePath: "/nonexistent")
        let script = command.arguments[1].replacingOccurrences(of: "exec /usr/bin/open", with: "echo")
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: command.executable)
        helper.arguments = ["-c", script] + command.arguments.dropFirst(2)
        let output = Pipe()
        helper.standardOutput = output
        try helper.run()
        helper.waitUntilExit()
        #expect(kill(pid, 0) != 0)
        #expect(Date().timeIntervalSince(started) > 0.3)
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(printed == "/nonexistent\n")
    }
}
