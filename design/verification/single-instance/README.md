# macOS launch verification

On November 23, 2026, five simultaneous launches of the release produced one cockpit. Five separate launches with another application in the foreground brought the original process forward each time. A relocated copy of the same bundle reused the existing cockpit. Turning the preference off allowed two processes. Re-enabling it preserved both windows and blocked a third. After force-quitting one owner, its surviving peer accepted the next launch. Quitting the last owner allowed a fresh start.

The arm64 release executable tested had SHA-256 `927a7c7939edb967c324f6b1ffcf72a2bbb9c6ad8594a281424165d56444715a`. The 16 focused launch tests passed ten consecutive runs. Independent Go tests exercised racing local service starts, independent profiles, stale sockets and a surviving service during restart.

Pressing ⌘, opened the Settings window in a signed QA copy of the release. The native switch started on, wrote the disabled preference when pressed and restored the enabled preference when pressed again. [Enabled](settings-on.png) · [Disabled](settings-off.png)

The final release also restored a hidden cockpit after ⌘H, a minimized cockpit, and a closed cockpit whose process was still running. Each forced duplicate exited successfully. In all three cases the original process recovered one visible, active cockpit window. The verifier removed its copied bundles and temporary preferences.

From the repository root, run this check on a signed app bundle in an unlocked macOS desktop session with Xcode Command Line Tools installed. Give the rehearsal the foreground while it runs.

```sh
python3 design/verification/single-instance/verify.py 'dist/Agent Commander.app'
```

The script creates an ad hoc signed copy with a unique bundle identifier, removes the service helpers, and opens the static design preview. Five simultaneous executable launches must leave one cockpit. It checks Launch Services and a relocated bundle, the persisted multiple-instance preference, preservation of existing windows when enforcement is enabled, handover after abrupt termination, and a fresh owner after the last instance exits. The disposable copy and its preferences are cleaned up afterward.

Add `--interactive` to exercise the native Settings switch and window restoration. Follow each checkpoint in the disposable **Commander Launch QA** app and enter `continue` in the terminal. The observer checks the application PID, foreground state and visible cockpit count at each step.
