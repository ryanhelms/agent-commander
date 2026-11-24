#!/usr/bin/env python3
"""Run the packaged launch policy in a separate macOS bundle and preference domain."""
import argparse
import concurrent.futures
import contextlib
import json
import os
import plistlib
import pwd
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
KEY = "AllowOnlyOneInstance"


def check(ok, message):
    if not ok:
        raise RuntimeError(message)


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def await_result(description, probe, timeout=15):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        result = probe()
        if result:
            return result
        time.sleep(0.12)
    raise RuntimeError("Timed out waiting for " + description)


class Rehearsal:
    def __init__(self, tmp, original, interactive):
        self.tmp = tmp
        self.interactive = interactive
        self.domain = "local.agentcommander.launch-qa." + uuid.uuid4().hex
        self.bundle = tmp / "Commander Launch QA.app"
        self.probe = tmp / "observe"
        self.children = []
        self.devnull = {"stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL}
        run("/usr/bin/ditto", original, self.bundle)
        meta = self.bundle / "Contents/Info.plist"
        info = plistlib.loads(meta.read_bytes())
        check(not info.get("LSMultipleInstancesProhibited", False),
              "Packaged Info.plist prohibits optional multiple instances")
        info.update(CFBundleIdentifier=self.domain, CFBundleName="Commander Launch QA",
                    CFBundleDisplayName="Commander Launch QA")
        meta.write_bytes(plistlib.dumps(info))
        self.exe = self.bundle / "Contents/MacOS" / info["CFBundleExecutable"]
        # No executable in this copy may contact a live service or a real Keychain.
        for name in ("agentctl", "commander-network"):
            helper = self.exe.parent / name
            if helper.exists():
                helper.unlink()
        run("/usr/bin/codesign", "--force", "--sign", "-", self.bundle, **self.devnull)
        run("/usr/bin/codesign", "--verify", "--strict", self.bundle)
        run("/usr/bin/clang", "-fobjc-arc", "-framework", "AppKit", "-framework", "CoreGraphics",
            HERE / "observe.m", "-o", self.probe)
        self.env = dict(os.environ, AGENT_COMMANDER_HOME=str(tmp / "service"),
                        AGENT_COMMANDER_SOCKET=str(tmp / "service.sock"),
                        COMMANDER_NETWORK_SOCKET=str(tmp / "network.sock"),
                        AGENT_COMMANDER_PREVIEW_STATIC="1", AGENT_COMMANDER_PREVIEW_GALLERY="hidden")
        self.env.pop("AGENT_COMMANDER_NETWORK_PANEL", None)
        self.env.pop("COMMANDER_NETWORK_BIN", None)

    def rows(self):
        raw = run(self.probe, self.domain, str(self.bundle.resolve()), capture_output=True).stdout
        return {row["pid"]: row for row in json.loads(raw)}

    def visible(self, want):
        def snapshot():
            rows = self.rows()
            if len(rows) == want and all(r["windows"] > 0 for r in rows.values()):
                return rows
            return None
        return await_result(f"{want} running test copies with visible cockpit windows", snapshot)

    def direct(self, executable=None):
        p = subprocess.Popen([executable or self.exe, "--design-preview", "coordinator-wall"], env=self.env,
                             stdin=subprocess.DEVNULL, **self.devnull)
        self.children.append(p)
        return p

    def launch_services(self, *, expect_exit=False):
        wait_flag = ["-W"] if expect_exit else []
        run("/usr/bin/open", "-n", *wait_flag, "-a", self.bundle, "--args", "--design-preview",
            "coordinator-wall", env=self.env, timeout=15, **self.devnull)

    def pref(self):
        result = subprocess.run(["/usr/bin/defaults", "read", self.domain, KEY], text=True, capture_output=True)
        return None if result.returncode else result.stdout.strip().lower() in ("true", "1", "yes")

    def gate(self, action):
        print("QA checkpoint:", action, flush=True)
        if sys.stdin.readline().strip() != "continue":
            raise RuntimeError("UI checkpoint ended before verification")

    def set_mode(self, single):
        if self.interactive:
            self.gate(f"In the test app's Settings, set {KEY} to {single}, then enter continue")
        else:
            run("/usr/bin/defaults", "write", self.domain, KEY, "-bool", str(single).lower())
        await_result(f"persistent preference {single}", lambda: self.pref() is single)

    def stop(self, pids, termination=signal.SIGTERM):
        rows = self.rows()
        for pid in set(pids) & set(rows):
            with contextlib.suppress(ProcessLookupError):
                os.kill(pid, termination)
        await_result("test copies to terminate", lambda: not (set(pids) & set(self.rows())))

    def cleanup(self):
        # Explicit Popen handles include very early launchers that may not have registered with AppKit.
        for child in self.children:
            if child.poll() is None:
                child.terminate()
        self.stop(self.rows())
        for child in self.children:
            with contextlib.suppress(subprocess.TimeoutExpired):
                child.wait(timeout=2)
        subprocess.run(["/usr/bin/defaults", "delete", self.domain], **self.devnull)
        library = Path(pwd.getpwuid(os.getuid()).pw_dir) / "Library"
        # Both paths use this run's generated UUID and never match a real bundle identifier.
        for folder in (library / "Application Support" / self.domain,
                       library / "Saved Application State" / (self.domain + ".savedState")):
            if folder.is_dir() and not folder.is_symlink() and folder.stat().st_uid == os.getuid():
                shutil.rmtree(folder)

    def exercise(self):
        print("QA app:", self.bundle, flush=True)
        print("QA domain:", self.domain, flush=True)
        check(self.pref() is None, "Expected factory default in a new domain")
        with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
            launchers = list(pool.map(lambda _: self.direct(), range(5)))
        await_result("four duplicate processes to exit",
                     lambda: sum(p.poll() is not None for p in launchers) == 4)
        rows = self.visible(1)
        winner = next(iter(rows))
        check(winner in {p.pid for p in launchers}, "Unexpected launch winner")
        check(all(p.pid == winner or p.returncode == 0 for p in launchers), "A losing copy crashed")
        self.launch_services(expect_exit=True)
        await_result("Launch Services to activate the original process",
                     lambda: (r := self.rows()) and set(r) == {winner} and r[winner]["active"])
        print(f"PASS default, five-way direct startup and Launch Services reuse (PID {winner})", flush=True)
        relocated = self.tmp / "Relocated Commander Launch QA.app"
        run("/usr/bin/ditto", self.bundle, relocated)
        same_id = self.direct(relocated / "Contents/MacOS" / self.exe.name)
        check(same_id.wait(timeout=12) == 0 and set(self.rows()) == {winner},
              "The same bundle identifier at a second path bypassed the launch policy")

        self.set_mode(False)
        self.stop([winner])
        first = self.direct()
        self.visible(1)
        self.launch_services()
        multiple = self.visible(2)
        check(first.pid in multiple and self.pref() is False, "Preference did not survive relaunch")
        print("PASS persisted opt-out and two independent windows via open -n", flush=True)
        self.set_mode(True)
        duplicate = self.direct()
        check(duplicate.wait(timeout=12) == 0, "Re-enabled preference allowed a third process")
        check(set(self.rows()) == set(multiple), "An existing opt-out process was unexpectedly terminated")
        focused = await_result("an existing copy to receive the duplicate", lambda:
                               next((p for p, r in self.rows().items() if r["active"]), None))
        self.stop([focused], signal.SIGKILL)
        survivor = next(iter(set(multiple) - {focused}))
        duplicate = self.direct()
        check(duplicate.wait(timeout=12) == 0, "Launch bypassed surviving owner")
        check(set(self.visible(1)) == {survivor}, "New process displaced original survivor")
        self.stop([survivor])
        last = self.direct()
        check(set(self.visible(1)) == {last.pid}, "No new owner could start after final owner exit")
        check(self.pref() is True and self.direct().wait(timeout=12) == 0,
              "The re-enabled preference did not persist after all prior copies exited")
        print("PASS re-enable, owner handover and clean acquisition after final exit", flush=True)

        if self.interactive:
            self.gate("Hide the QA application, then enter continue")
            await_result("original app to hide", lambda: self.rows().get(last.pid, {}).get("hidden"))
            duplicate = self.direct()
            check(duplicate.wait(timeout=12) == 0, "Duplicate did not exit cleanly")
            await_result("hidden owner to regain its visible, active window", lambda:
                         (r := self.rows().get(last.pid, {})).get("active") and r["windows"] == 1 and not r["hidden"])
            self.gate("Minimize the QA cockpit, then enter continue")
            await_result("cockpit window to minimize", lambda:
                         last.pid in (r := self.rows()) and not r[last.pid]["hidden"] and r[last.pid]["windows"] == 0)
            check(self.direct().wait(timeout=12) == 0, "Duplicate stayed open while the cockpit was minimized")
            await_result("owner to restore the minimized cockpit", lambda:
                         (r := self.rows().get(last.pid, {})).get("active") and r["windows"] == 1)
            self.gate("Close the QA cockpit window, leaving its process alive, then enter continue")
            await_result("original process with no cockpit window", lambda:
                         last.pid in (r := self.rows()) and r[last.pid]["windows"] == 0)
            self.launch_services(expect_exit=True)
            await_result("reactivated owner to reopen its cockpit", lambda:
                         (r := self.rows().get(last.pid, {})).get("active") and r["windows"] == 1)
            print("PASS hidden, minimized and closed cockpit restored in original process", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path, help="a packaged Agent Commander.app")
    parser.add_argument("--interactive", action="store_true", help="also verify hiding, window close and the actual Settings toggle")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="commander-launch-qa-", dir="/private/tmp") as directory:
        fixture = Rehearsal(Path(directory), args.bundle.resolve(), args.interactive)
        try:
            fixture.exercise()
        finally:
            fixture.cleanup()


if __name__ == "__main__":
    main()
