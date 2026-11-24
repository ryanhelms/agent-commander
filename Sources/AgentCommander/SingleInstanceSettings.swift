import CoreFoundation
import SwiftUI

// ATOMIC LEVEL: molecule, organism and page for the native Settings scene
// (Agent Commander > Settings…, ⌘, from the system command).
//
//   Toggle (.switch)              atom: native, accessible name "Allow only one instance"
//   SettingStateSwitch            molecule: On/Off word + the native switch, as on the Preferences page
//   LaunchSettingsSection         organism: kicker, heading, SettingRow panel
//   SingleInstanceSettingsPage    page: binds UserDefaults.standard
//
// The section takes a binding only. It knows nothing about leases or markers.

enum SingleInstancePreference {
    static let key = "AllowOnlyOneInstance"
    static let defaultValue = true

    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }

    /// Hands the current app's pending preference writes to cfprefsd now, so a launch started a
    /// moment after the switch changes reads the new value.
    static func commit() {
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    }
}

/// The state word beside a native switch. The switch carries the name and value for VoiceOver.
struct SettingStateSwitch: View {
    let title: String
    let identifier: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 9) {
            Text(isOn ? "On" : "Off")
                .font(.system(size: 13))
                .foregroundStyle(.inkSecondary)
                .accessibilityHidden(true)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Palette.accentBottom)
                .accessibilityIdentifier(identifier)
        }
    }
}

struct LaunchSettingsSection: View {
    @Binding var allowsOnlyOneInstance: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 11) {
                    Kicker(text: "General")
                    Text("Launching Commander")
                        .font(.system(size: 22, weight: .semibold)).tracking(-0.7)
                        .foregroundStyle(Palette.foreground)
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: Space.m)
                Label("App preference", systemImage: "macwindow")
                    .font(.system(size: 12.5)).foregroundStyle(.inkSecondary)
            }
            SettingRow(title: "Allow only one instance",
                       detail: "Opening Commander again brings the open cockpit forward.") {
                SettingStateSwitch(title: "Allow only one instance", identifier: SingleInstancePreference.key,
                                   isOn: $allowsOnlyOneInstance)
            }
            .panelSurface()
        }
    }
}

struct SingleInstanceSettingsPage: View {
    @AppStorage(SingleInstancePreference.key) private var allowsOnlyOneInstance = SingleInstancePreference.defaultValue

    var body: some View {
        LaunchSettingsSection(allowsOnlyOneInstance: $allowsOnlyOneInstance)
            .onChange(of: allowsOnlyOneInstance) { SingleInstancePreference.commit() }
            .padding(Space.xl)
            .frame(width: 560, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .containerBackground(Palette.window, for: .window)
            .preferredColorScheme(.dark)
    }
}
