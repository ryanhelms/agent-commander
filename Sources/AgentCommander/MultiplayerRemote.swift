import CoreImage
import CoreImage.CIFilterBuiltins
import Observation
import SwiftUI

// REMOTE (design/COMMANDER-NETWORK-INCREMENT-6.md): the web view this Mac serves over the tailnet
// for approvals and watching from a phone. The tray turns it on and off, shows the pairing code
// with a QR code of the pairing link, and lists the paired devices with a way to revoke each.
// The device agent's verbs name no server: `remote-enable` {listen?}, `remote-disable`,
// `remote-devices`, `remote-revoke` {device} and `remote-rename` {device, name}.
//   Contract:  MultiplayerRemotePairing, MultiplayerRemoteDevice, MultiplayerRemoteStatus
//   Model:     MultiplayerRemoteModel
//   Atoms:     MultiplayerQRCode, MultiplayerInsetFocusRing
//   Molecules: MultiplayerCopyChip, MultiplayerRemoteDeviceRow
//   Organism:  MultiplayerRemoteBand
// Components take values and emit actions; the tray wires them to MultiplayerRemoteModel.

// MARK: - Contract

/// What `remote-enable` returns: where the web view is served, and a code that pairs one device.
struct MultiplayerRemotePairing: Equatable, Sendable {
    let url: String
    /// Eight characters. It works once and lasts ten minutes.
    let code: String
    let expiresAt: Date
    /// `<url>/pair?code=<code>`: what the QR code holds.
    let pairURL: String

    static let lifetime: TimeInterval = 600

    init(url: String, code: String, expiresAt: Date, pairURL: String) {
        self.url = url
        self.code = code
        self.expiresAt = expiresAt
        self.pairURL = pairURL
    }

    init?(_ json: MultiplayerJSON, now: Date) {
        guard let url = json.firstText("url"), let code = json.firstText("code") else { return nil }
        self.url = url
        self.code = code
        expiresAt = json["expiresAt"]?.text.flatMap(MultiplayerTime.parse) ?? now.addingTimeInterval(Self.lifetime)
        pairURL = json.firstText("pairURL") ?? "\(url)/pair?code=\(code)"
    }

    func isLive(now: Date) -> Bool { expiresAt > now }

    /// "ABCD EFGH": two groups are easier to read across a room.
    var spacedCode: String {
        code.count == 8 ? "\(code.prefix(4)) \(code.suffix(4))" : code
    }

    /// The same code letter by letter, so VoiceOver doesn't read it as a word.
    var spokenCode: String { code.map(String.init).joined(separator: " ") }
}

/// A phone or tablet paired with this Mac's web view.
struct MultiplayerRemoteDevice: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let paired: Date?
    /// When its session ends by itself, 30 days after pairing.
    let expires: Date?

    /// The device agent takes a name of 1 to 64 bytes.
    static let nameLimit = 64

    init(id: String, name: String, paired: Date? = nil, expires: Date? = nil) {
        self.id = id
        self.name = name
        self.paired = paired
        self.expires = expires
    }

    /// A typed name as it is sent: trimmed. Nil when it is empty or too long to send.
    static func sendable(name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.utf8.count > nameLimit ? nil : trimmed
    }

    /// Why a typed name can't be sent. Nil while it can, and while nothing is typed yet.
    static func problem(name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.utf8.count > nameLimit ? "Use a shorter name: \(nameLimit) characters at most." : nil
    }

    func named(_ name: String) -> MultiplayerRemoteDevice {
        MultiplayerRemoteDevice(id: id, name: name, paired: paired, expires: expires)
    }

    init?(_ json: MultiplayerJSON) {
        guard let id = json.firstText("id") else { return nil }
        self.id = id
        name = MultiplayerText.clean(json.firstText("name") ?? "Phone", limit: 60)
        paired = json["paired"]?.text.flatMap(MultiplayerTime.parse)
        expires = json["expires"]?.text.flatMap(MultiplayerTime.parse)
    }
}

/// What `remote-devices` returns.
struct MultiplayerRemoteStatus: Equatable, Sendable {
    var running = false
    var url = ""
    var devices: [MultiplayerRemoteDevice] = []
    /// The unused code the device agent still offers, so a tray that restarts draws the same QR code.
    var pairing: MultiplayerRemotePairing?

    init(running: Bool = false, url: String = "", devices: [MultiplayerRemoteDevice] = [],
         pairing: MultiplayerRemotePairing? = nil) {
        self.running = running
        self.url = url
        self.devices = devices
        self.pairing = pairing
    }

    init(_ json: MultiplayerJSON, now: Date = Date()) {
        if case .bool(let value) = json["running"] ?? .null { running = value }
        url = json.firstText("url") ?? ""
        devices = MultiplayerUnique.keep((json["devices"]?.items ?? []).compactMap(MultiplayerRemoteDevice.init)) { $0.id }
        // `pairing` is {code, expiresAt, pairURL}: the address is the status's own.
        if running, !url.isEmpty, let offer = json["pairing"], let code = offer.firstText("code"), !code.isEmpty {
            pairing = MultiplayerRemotePairing(
                url: url, code: code,
                expiresAt: offer["expiresAt"]?.text.flatMap(MultiplayerTime.parse) ?? now.addingTimeInterval(MultiplayerRemotePairing.lifetime),
                pairURL: offer.firstText("pairURL") ?? "\(url)/pair?code=\(code)")
        }
    }
}

extension MultiplayerClient {
    /// Starts the web view if it is off, and makes a new pairing code either way.
    func remoteEnable(now: Date) async throws -> MultiplayerRemotePairing {
        guard let pairing = MultiplayerRemotePairing(try await fetch(.remoteEnable, [:], as: MultiplayerJSON.self), now: now) else {
            throw MultiplayerFailure.invalidResponse
        }
        return pairing
    }

    /// Stops the web view. Paired devices stay paired.
    func remoteDisable() async throws {
        _ = try await fetch(.remoteDisable, [:], as: MultiplayerIgnored.self, allowsEmpty: true)
    }

    func remoteDevices(now: Date = Date()) async throws -> MultiplayerRemoteStatus {
        MultiplayerRemoteStatus(try await fetch(.remoteDevices, [:], as: MultiplayerJSON.self), now: now)
    }

    func remoteRename(device: String, name: String) async throws {
        _ = try await fetch(.remoteRename, ["device": .string(device), "name": .string(name)], as: MultiplayerIgnored.self,
                            allowsEmpty: true)
    }

    func remoteRevoke(device: String) async throws {
        _ = try await fetch(.remoteRevoke, ["device": .string(device)], as: MultiplayerIgnored.self, allowsEmpty: true)
    }
}

// MARK: - Model

/// The Remote band's state. Turning the web view on or off, making a code and revoking a device go
/// through the tray's one action at a time, so progress and refusal show in the tray's banner.
@Observable @MainActor
final class MultiplayerRemoteModel {
    @ObservationIgnored weak var tray: MultiplayerModel?

    private(set) var status: MultiplayerRemoteStatus?
    /// Why the last read failed. Nil while it works.
    private(set) var failure: String?
    /// The code on show: the one this tray made, or the unused one the device agent still offers.
    private(set) var pairing: MultiplayerRemotePairing?
    /// The device whose Revoke is waiting for a second click.
    private(set) var confirmingRevoke: String?
    /// The device whose name is being edited.
    private(set) var renaming: String?

    private let client: MultiplayerClient?
    private let clock: () -> Date
    @ObservationIgnored private(set) var quietTask: Task<Void, Never>?

    init(client: MultiplayerClient?, now: @escaping () -> Date = { Date() }) {
        self.client = client
        self.clock = now
    }

    var isRunning: Bool { status?.running == true }
    var devices: [MultiplayerRemoteDevice] { status?.devices ?? [] }

    /// The code to show: only while the web view runs and the code can still pair.
    var livePairing: MultiplayerRemotePairing? {
        guard isRunning, let pairing, pairing.isLive(now: clock()) else { return nil }
        return pairing
    }

    /// True when a code was made and has run out without pairing anything.
    var pairingExpired: Bool {
        guard isRunning, let pairing else { return false }
        return !pairing.isLive(now: clock())
    }

    /// Reads whether the web view runs and which devices are paired.
    func refresh() {
        guard let client, let tray, tray.viewers > 0, quietTask == nil else { return }
        quietTask = Task {
            do {
                self.take(try await client.remoteDevices(now: self.clock()))
                self.failure = nil
            } catch {
                let reason = MultiplayerFailure.from(error)
                if reason != .cancelled { self.failure = reason.message }
            }
            self.quietTask = nil
        }
    }

    func cancel() {
        quietTask?.cancel()
        quietTask = nil
        confirmingRevoke = nil
        renaming = nil
    }

    /// Takes a fresh device list. A code is used up by the device it paired, so a new device ends it.
    func take(_ next: MultiplayerRemoteStatus) {
        let known = Set((status?.devices ?? []).map(\.id))
        let arrived = next.devices.filter { !known.contains($0.id) }
        if status != nil, pairing != nil, let device = arrived.first {
            pairing = nil
            tray?.post(notice: "Paired \(device.name.multiplayerDisplay). It can approve requests and watch from the web view.")
        }
        // The device agent names the code only while it can still pair, so its code is the one to show.
        if let offered = next.pairing { pairing = offered }
        if !next.running { pairing = nil }
        if let asked = confirmingRevoke, !next.devices.contains(where: { $0.id == asked }) { confirmingRevoke = nil }
        if let edited = renaming, !next.devices.contains(where: { $0.id == edited }) { renaming = nil }
        status = next
    }

    func setRunning(_ on: Bool) { on ? enable() : disable() }

    /// Turns the web view on, or makes a new code when it is on already.
    @discardableResult
    func enable() -> Task<Void, Never>? {
        let wasRunning = isRunning
        return tray?.act(wasRunning ? "Making a new pairing code…" : "Turning Remote on…",
                         failing: wasRunning ? "Couldn’t make a pairing code." : "Couldn’t turn Remote on.") { client in
            let pairing = try await client.remoteEnable(now: self.clock())
            self.pairing = pairing
            var next = self.status ?? MultiplayerRemoteStatus()
            next.running = true
            next.url = pairing.url
            self.status = next
            if let listed = try? await client.remoteDevices(now: self.clock()) { self.take(listed) }
        }
    }

    @discardableResult
    func disable() -> Task<Void, Never>? {
        confirmingRevoke = nil
        renaming = nil
        return tray?.act("Turning Remote off…", failing: "Couldn’t turn Remote off.",
                         confirmation: "Remote is off. Paired devices stay paired for when you turn it on again.") { client in
            try await client.remoteDisable()
            self.pairing = nil
            var next = self.status ?? MultiplayerRemoteStatus()
            next.running = false
            next.url = ""
            self.status = next
        }
    }

    /// The first click on Revoke: asks. Nothing is sent.
    func askRevoke(_ device: String) {
        renaming = nil
        confirmingRevoke = device
    }
    func cancelRevoke() { confirmingRevoke = nil }

    /// Opens the name field on one device. Nothing is sent.
    func startRename(_ device: String) {
        confirmingRevoke = nil
        renaming = device
    }
    func cancelRename() { renaming = nil }

    /// Sends the typed name for the device being renamed. The same name closes the field unsent.
    @discardableResult
    func rename(to typed: String) -> Task<Void, Never>? {
        guard let id = renaming, let device = devices.first(where: { $0.id == id }),
              let name = MultiplayerRemoteDevice.sendable(name: typed) else { return nil }
        guard name != device.name else {
            renaming = nil
            return nil
        }
        let old = device.name.multiplayerDisplay
        return tray?.act("Renaming \(old)…", failing: "Couldn’t rename \(old).",
                         confirmation: "\(old) is now \(name.multiplayerDisplay).") { client in
            try await client.remoteRename(device: id, name: name)
            self.renaming = nil
            if let index = self.status?.devices.firstIndex(where: { $0.id == id }) {
                self.status?.devices[index] = device.named(MultiplayerText.clean(name, limit: 60))
            }
        }
    }

    @discardableResult
    func confirmRevoke() -> Task<Void, Never>? {
        guard let id = confirmingRevoke, let device = devices.first(where: { $0.id == id }) else { return nil }
        let name = device.name.multiplayerDisplay
        return tray?.act("Revoking \(name)…", failing: "Couldn’t revoke \(name).",
                         confirmation: "\(name) is signed out. It has to pair again to use the web view.") { client in
            try await client.remoteRevoke(device: id)
            self.confirmingRevoke = nil
            self.status?.devices.removeAll { $0.id == id }
        }
    }
}

// MARK: - Atoms and molecules

/// A QR code drawn module by module on whole points, so it is crisp at any scale. Dark modules on
/// a light tile, with the standard four-module quiet zone: phone cameras read that most reliably.
struct MultiplayerQRCode: View {
    static let quietZone = 4
    static let maxSide: CGFloat = 164

    let text: String
    /// Said in place of the picture.
    let label: String
    @State private var printed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The code's modules, row by row; true is dark. Nil when the text can't be encoded.
    static func modules(for text: String) -> [[Bool]]? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage else { return nil }
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0, width <= 177 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        CIContext(options: [.useSoftwareRenderer: true])
            .render(image, toBitmap: &pixels, rowBytes: width * 4, bounds: extent, format: .RGBA8,
                    colorSpace: CGColorSpaceCreateDeviceRGB())
        var rows = (0..<height).map { row in (0..<width).map { pixels[(row * width + $0) * 4] < 128 } }
        // Core Image adds its own one-module margin. Drop it: the view draws the full quiet zone.
        while let first = rows.first, !first.contains(true) { rows.removeFirst() }
        while let last = rows.last, !last.contains(true) { rows.removeLast() }
        let left = rows.compactMap { $0.firstIndex(of: true) }.min() ?? 0
        let right = rows.compactMap { $0.lastIndex(of: true) }.max() ?? -1
        guard !rows.isEmpty, right - left + 1 == rows.count else { return nil }
        return rows.map { Array($0[left...right]) }
    }

    /// Whole points per module, so no module edge lands between pixels.
    static func moduleSize(count: Int) -> CGFloat {
        max(2, (maxSide / CGFloat(count + quietZone * 2)).rounded(.down))
    }

    @Environment(\.theme) private var theme
    var body: some View {
        let shape = theme.trayTile
        Group {
            if let modules = Self.modules(for: text) {
                let unit = Self.moduleSize(count: modules.count)
                let side = unit * CGFloat(modules.count + Self.quietZone * 2)
                Canvas(rendersAsynchronously: false) { context, _ in
                    var dark = Path()
                    for (y, row) in modules.enumerated() {
                        for (x, isDark) in row.enumerated() where isDark {
                            dark.addRect(CGRect(x: CGFloat(x + Self.quietZone) * unit, y: CGFloat(y + Self.quietZone) * unit,
                                                width: unit, height: unit))
                        }
                    }
                    context.fill(dark, with: .color(Palette.window))
                }
                .frame(width: side, height: side)
                // The code prints from the top down once; with Reduce Motion it fades in.
                .mask(alignment: .top) {
                    Rectangle().frame(height: reduceMotion || printed ? side : 0)
                }
                .opacity(reduceMotion && !printed ? 0 : 1)
                .background(MultiplayerTheme.foreground)
                .clipShape(shape)
                .overlay { shape.strokeBorder(MultiplayerTheme.hair) }
                .onAppear {
                    withAnimation(.easeOut(duration: MultiplayerTheme.Motion.slow)) { printed = true }
                }
            } else {
                Text("This link is too long for a QR code. Copy it instead.")
                    .font(MultiplayerTheme.sub)
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: Self.maxSide, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(label)
    }
}

/// The focus ring for a control whose frame clips the system's ring, such as a cell joined to its
/// neighbours on one hairline: 2 pt of `focus` drawn inside the control's own edge while it has
/// keyboard focus. The control stays a native button; only where the ring is drawn changes.
struct MultiplayerInsetFocusRing: ViewModifier {
    /// Draws the ring without focus, for a headless picture.
    var forced = false
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .focusEffectDisabled()
            .overlay {
                if focused || forced {
                    Rectangle().strokeBorder(MultiplayerTheme.focus, lineWidth: 2).allowsHitTesting(false)
                }
            }
    }
}

/// A value shown as data with a way to copy it: a label cell, the value, and a copy cell, joined on
/// one hairline frame. The copy cell shows a tick once it has copied.
struct MultiplayerCopyChip: View {
    let label: String
    let value: String
    /// What VoiceOver says for the value, when the drawn text would be read badly.
    var spoken: String? = nil
    var font: MultiplayerType = MultiplayerTheme.data
    var height: CGFloat = 22
    /// Draws the copy cell's focus ring without focus, for a headless picture.
    var showsFocus = false
    let onCopy: (String) -> Void
    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(\.theme) private var theme
    var body: some View {
        let shape = theme.trayChip
        HStack(spacing: 0) {
            Text(label)
                .font(MultiplayerTheme.label)
                .foregroundStyle(.inkSecondary)
                .padding(.horizontal, 6)
                .frame(maxHeight: .infinity)
                .background(MultiplayerTheme.well)
            Rectangle().fill(MultiplayerTheme.border).frame(width: 1)
            Text(value)
                .font(font)
                .foregroundStyle(MultiplayerTheme.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.horizontal, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(MultiplayerTheme.border).frame(width: 1)
            Button {
                onCopy(value)
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.6))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(copied ? MultiplayerTheme.working : MultiplayerTheme.secondary)
                    .frame(width: 24)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MultiplayerRowButtonStyle())
            .modifier(MultiplayerInsetFocusRing(forced: showsFocus))
            .help("Copy the \(label)")
            .accessibilityLabel(copied ? "Copied the \(label)" : "Copy the \(label)")
        }
        .frame(height: height)
        .clipShape(shape)
        .overlay { shape.strokeBorder(MultiplayerTheme.border) }
        .animation(reduceMotion ? nil : MultiplayerTheme.Motion.ease(MultiplayerTheme.Motion.fast), value: copied)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(label), \(spoken ?? value)")
    }
}

/// A paired device: what it is called, when it paired and when its session ends, Rename and
/// Revoke. Rename opens a name field under the row; Revoke asks under the row before it sends.
struct MultiplayerRemoteDeviceRow: View {
    let device: MultiplayerRemoteDevice
    let now: Date
    let isConfirming: Bool
    var isRenaming = false
    let isBusy: Bool
    var onRename: () -> Void = {}
    var onCancelRename: () -> Void = {}
    var onSubmitName: (String) -> Void = { _ in }
    let onRevoke: () -> Void
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        let name = device.name.multiplayerDisplay
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Space.s) {
                MultiplayerMark(symbol: "iphone", tone: .neutral, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(MultiplayerTheme.name)
                        .foregroundStyle(MultiplayerTheme.foreground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(Self.dates(device, now: now))
                        .font(MultiplayerTheme.fingerprint)
                        .foregroundStyle(.inkSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel("\(name), \(Self.dates(device, now: now))")
                if !isConfirming, !isRenaming {
                    Button("Rename", action: onRename)
                        .buttonStyle(MultiplayerTrayButtonStyle())
                        .disabled(isBusy)
                        .help("Give this device a name you’ll recognise")
                        .accessibilityLabel("Rename \(name)")
                    Button("Revoke", action: onRevoke)
                        .buttonStyle(MultiplayerTrayButtonStyle(role: .danger))
                        .disabled(isBusy)
                        .help("Sign this device out of the web view")
                        .accessibilityLabel("Revoke \(name)")
                }
            }
            if isRenaming {
                MultiplayerRemoteNameEditor(current: device.name, isBusy: isBusy, onCancel: onCancelRename, onSave: onSubmitName)
            }
            if isConfirming {
                MultiplayerInlineConfirm(message: "Revoke \(name)? It is signed out at once and has to pair again.",
                                         keepTitle: "Keep", confirmTitle: "Revoke", isBusy: isBusy,
                                         onCancel: onCancel, onConfirm: onConfirm)
            }
        }
        .padding(.vertical, 5)
        .overlay(alignment: .top) { Rectangle().fill(MultiplayerTheme.hair).frame(height: 1) }
    }

    /// "paired Nov 25, ends Dec 25".
    static func dates(_ device: MultiplayerRemoteDevice, now: Date) -> String {
        let day = Date.FormatStyle().month(.abbreviated).day()
        let parts = [device.paired.map { "paired \($0.formatted(day))" },
                     device.expires.map { $0 > now ? "ends \($0.formatted(day))" : "session ended" }]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }
}

/// The name field a device row opens: the field with the name in it, then Cancel and Save. Return
/// saves and Escape cancels. The draft lives here; the row hears only the name to send.
struct MultiplayerRemoteNameEditor: View {
    let current: String
    let isBusy: Bool
    let onCancel: () -> Void
    let onSave: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var sendable: String? { MultiplayerRemoteDevice.sendable(name: draft) }

    var body: some View {
        MultiplayerWell {
            VStack(alignment: .leading, spacing: Space.s) {
                MultiplayerField(label: "Device name", problem: MultiplayerRemoteDevice.problem(name: draft)) {
                    MultiplayerTextField(label: "Device name", placeholder: "Kitchen iPad", text: $draft, isFocused: focused)
                        .focused($focused)
                        .onSubmit { if let sendable, !isBusy { onSave(sendable) } }
                }
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Button("Cancel", action: onCancel).buttonStyle(MultiplayerTrayButtonStyle())
                    Button("Save name") { if let sendable { onSave(sendable) } }
                        .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                        .disabled(isBusy || sendable == nil)
                }
            }
        }
        .onExitCommand(perform: onCancel)
        .onAppear {
            draft = current
            focused = true
        }
        .multiplayerArriving()
    }
}

// MARK: - Organism

/// Remote: the switch for this Mac's web view, the pairing code as a QR code and as data, and the
/// devices paired with it.
struct MultiplayerRemoteBand: View {
    /// Nil until the device agent has answered once.
    let status: MultiplayerRemoteStatus?
    let failure: String?
    let pairing: MultiplayerRemotePairing?
    let pairingExpired: Bool
    let confirmingRevoke: String?
    var renaming: String? = nil
    let now: Date
    let isBusy: Bool
    let onSetRunning: (Bool) -> Void
    let onNewCode: () -> Void
    let onCopy: (String) -> Void
    let onAskRevoke: (String) -> Void
    let onCancelRevoke: () -> Void
    let onConfirmRevoke: () -> Void
    var onStartRename: (String) -> Void = { _ in }
    var onCancelRename: () -> Void = {}
    var onRename: (String) -> Void = { _ in }
    let onRetry: () -> Void

    private var isRunning: Bool { status?.running == true }
    private var devices: [MultiplayerRemoteDevice] { status?.devices ?? [] }

    var body: some View {
        MultiplayerBand {
            VStack(alignment: .leading, spacing: Space.s) {
                MultiplayerBandHeading(title: "Remote", count: devices.isEmpty ? nil : "\(devices.count)") {
                    Toggle("Remote web view", isOn: Binding(get: { isRunning }, set: onSetRunning))
                        .toggleStyle(MultiplayerSwitchStyle())
                        .disabled(isBusy || status == nil)
                        .help(isRunning ? "Stop serving the web view. Paired devices stay paired."
                                        : "Serve the web view on this Mac’s tailnet address")
                }
                if let status {
                    summary(status)
                    if isRunning { pairingBlock }
                    deviceList
                } else {
                    MultiplayerLoadNote(loading: "Reading Remote from this Mac…", failure: failure, onRetry: onRetry)
                }
            }
            .multiplayerStreaming(isRunning)
            .multiplayerStreaming(pairing?.code ?? "")
            .multiplayerStreaming(devices.map(\.id))
            .multiplayerStreaming(confirmingRevoke ?? "")
            .multiplayerStreaming(renaming ?? "")
        }
        // Tab visits every control in the band before it leaves. Without this the order follows each
        // control's place in the window, and a row scrolled under the footer is reached after it.
        .focusSection()
    }

    @ViewBuilder private func summary(_ status: MultiplayerRemoteStatus) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            MultiplayerStateLabel(lamp: isRunning ? .on : .off, text: isRunning ? "Serving" : "Off",
                                  tone: isRunning ? .working : .neutral)
            Text(isRunning ? "Approve requests and watch workers from a paired phone, on your tailnet only."
                           : "A web page this Mac serves on your tailnet, for approving and watching from a phone.")
                .font(MultiplayerTheme.sub)
                .foregroundStyle(.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if isRunning, !status.url.isEmpty {
            MultiplayerCopyChip(label: "address", value: status.url, onCopy: onCopy)
                .multiplayerArriving()
        }
    }

    @ViewBuilder private var pairingBlock: some View {
        if let pairing {
            HStack(alignment: .top, spacing: Space.m) {
                MultiplayerQRCode(text: pairing.pairURL, label: "QR code of the pairing link")
                    .id(pairing.code)
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("Scan with a phone on your tailnet")
                        .font(MultiplayerTheme.name)
                        .foregroundStyle(MultiplayerTheme.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    MultiplayerCopyChip(label: "code", value: pairing.spacedCode, spoken: pairing.spokenCode,
                                        font: MultiplayerTheme.figure, height: 28, onCopy: { _ in onCopy(pairing.code) })
                    HStack(alignment: .top, spacing: Space.s) {
                        Text("The code pairs one device, then ends.")
                            .font(MultiplayerTheme.sub)
                            .foregroundStyle(.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        MultiplayerCountdown(until: pairing.expiresAt, span: MultiplayerRemotePairing.lifetime)
                    }
                    MultiplayerCopyChip(label: "link", value: pairing.pairURL, onCopy: onCopy)
                    Button("New code", action: onNewCode)
                        .buttonStyle(MultiplayerTrayButtonStyle())
                        .disabled(isBusy)
                        .help("Replace this code with a new one")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .multiplayerArriving()
        } else {
            HStack(spacing: Space.s) {
                MultiplayerStateLabel(lamp: pairingExpired ? .waiting : .off,
                                      text: pairingExpired ? "Code expired" : "No code",
                                      tone: pairingExpired ? .attention : .neutral)
                Text(pairingExpired ? "It lasted ten minutes and paired nothing." : "Make a code to pair a phone or tablet.")
                    .font(MultiplayerTheme.sub)
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Pair a device", action: onNewCode)
                    .buttonStyle(MultiplayerTrayButtonStyle(role: .primary))
                    .disabled(isBusy)
                    .help("Make a pairing code and show its QR code")
            }
        }
    }

    @ViewBuilder private var deviceList: some View {
        if devices.isEmpty {
            if isRunning {
                HStack(spacing: Space.s) {
                    MultiplayerLamp(kind: .off)
                    Text("No device is paired yet.").font(MultiplayerTheme.sub).foregroundStyle(.inkSecondary)
                }
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(MultiplayerTheme.hair).frame(height: 1) }
                .accessibilityElement(children: .combine)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(devices) { device in
                    MultiplayerRemoteDeviceRow(device: device, now: now, isConfirming: confirmingRevoke == device.id,
                                               isRenaming: renaming == device.id, isBusy: isBusy,
                                               onRename: { onStartRename(device.id) }, onCancelRename: onCancelRename,
                                               onSubmitName: onRename,
                                               onRevoke: { onAskRevoke(device.id) }, onCancel: onCancelRevoke,
                                               onConfirm: onConfirmRevoke)
                        .multiplayerArriving()
                }
            }
        }
    }
}
