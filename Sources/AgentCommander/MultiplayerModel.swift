import Foundation
import Observation

// FEATURE MODEL: one server's session (account, friends, resources and grants on that relay).
// The tray's MultiplayerModel keeps one of these per saved server, each with a client scoped to it.
// Owns the helper calls, the poll while a panel is open, drafts and the session route. Components
// receive its values and call its intents. Rules it keeps:
// - Online is shown only from a definite status reply; a failed or missing reply is never online.
// - One mutation at a time. Starting one drops any status read in flight; success triggers a fresh
//   read, so a stale reply can never overwrite the result of a user's action.
// - Polling pauses while a mutation, a lookup or an editor is active, and stops when the panel closes.
// - A confirmation is shown only after the helper confirms.
// - Browser sign-in state comes from the service's `loginPending`, never from local memory alone.
// - A repository token lives only in `credentialEntry` and the one delivery call. It is never part
//   of a command, failure, notice, route or retry.
// - A grant's limits are fixed when the owner chooses Review. The confirmation shows that command
//   and Grant access sends exactly it. If its expiry has passed, nothing is sent and the owner
//   reviews fresh limits.

enum MultiplayerPresence: Equatable {
    case offline
    case checking
    case signedOut
    case waitingForBrowser
    /// Browser sign-in can be started again. Carries the service's display-safe reason, when it gave one.
    case signInIncomplete(detail: String?)
    case needsHandle
    case online(handle: String)
    /// The service reported a problem; carries display-safe text.
    case serviceError(String)
    case unavailable(String)

    var title: String {
        switch self {
        case .offline: "Offline"
        case .checking: "Checking…"
        case .signedOut: "Signed out"
        case .waitingForBrowser: "Waiting for browser"
        case .signInIncomplete: "Sign-in didn’t finish"
        case .needsHandle: "Handle needed"
        case .online: "Online"
        case .serviceError: "Service problem"
        case .unavailable: "Unavailable"
        }
    }

    var tone: Tone {
        switch self {
        case .online: .working
        case .waitingForBrowser, .needsHandle, .signInIncomplete: .attention
        case .unavailable, .serviceError: .failure
        case .checking: .focus
        case .offline, .signedOut: .neutral
        }
    }

    /// A filled light for a state that is live or needs the developer; a hollow ring otherwise.
    var isLit: Bool {
        switch self {
        case .online, .waitingForBrowser, .needsHandle, .signInIncomplete, .serviceError, .unavailable: true
        case .offline, .checking, .signedOut: false
        }
    }

    var menuSymbol: String {
        switch self {
        case .online: "person.2.fill"
        case .unavailable, .serviceError: "person.2.slash"
        default: "person.2"
        }
    }
}

enum MultiplayerRoute: Equatable {
    case home
    case addFriend
    case addResource
    case grant
    case confirmGrant
    case confirmRevoke(MultiplayerGrant)
    /// The GitHub token editor for one of your own repositories, by resource ID. Never holds the token.
    case repoCredential(resourceID: String)
}

/// The outcome of a token delivery that didn't confirm. Holds names only, never the token or the
/// helper's text, which could echo it.
struct MultiplayerCredentialFailure: Equatable {
    let resourceID: String
    let resourceName: String
    let failure: MultiplayerFailure

    var message: String {
        let name = resourceName.multiplayerDisplay
        if failure == .cancelled || failure.outcomeUnknown {
            return "Commander couldn’t confirm the GitHub token for \(name) was saved. Enter it again to be sure."
        }
        switch failure {
        case .rejected, .invalidInput:
            return "The helper didn’t save the GitHub token for \(name). Check it’s limited to this repository, then enter it again."
        default:
            return "The GitHub token for \(name) wasn’t saved. \(failure.message)"
        }
    }

    var actionTitle: String? { failure.canRetry ? "Enter again" : nil }
}

enum MultiplayerLookup: Equatable {
    case idle
    case searching(String)
    case found(String)
    case failed(handle: String, message: String)

    var handle: String? {
        switch self {
        case .idle: nil
        case .searching(let handle), .found(let handle), .failed(let handle, _): handle
        }
    }
}

struct MultiplayerActionFailure: Equatable {
    let command: MultiplayerCommand
    let failure: MultiplayerFailure

    var message: String {
        if failure == .cancelled {
            return "The panel closed before the network helper confirmed the \(command.noun). Check status before trying again."
        }
        if failure.outcomeUnknown {
            return "\(failure.message) The \(command.noun) may still have gone through, so check status before trying again."
        }
        return "\(command.failureTitle) \(failure.message)"
    }

    /// An unconfirmed outcome is checked, never re-sent.
    var actionTitle: String? {
        guard failure.canRetry else { return nil }
        return failure.outcomeUnknown ? "Check status" : "Try again"
    }
}

@Observable @MainActor
final class MultiplayerSessionModel {
    private(set) var status: MultiplayerStatus?
    private(set) var statusFailure: MultiplayerFailure?
    private(set) var isRefreshing = false
    private(set) var running: MultiplayerCommand?
    private(set) var actionFailure: MultiplayerActionFailure?
    private(set) var notice: String?
    /// Bridges a confirmed `login` to the next status; that status then decides.
    private(set) var awaitingBrowser = false
    /// The last status ended a pending sign-in without signing in.
    private(set) var signInIncomplete = false
    private(set) var route: MultiplayerRoute = .home
    private(set) var lookup: MultiplayerLookup = .idle
    /// Name of the repository whose token is being delivered.
    private(set) var savingCredentialFor: String?
    private(set) var credentialFailure: MultiplayerCredentialFailure?
    /// The grant exactly as reviewed, with absolute limits. Present only on the confirmation step.
    private(set) var reviewedGrant: MultiplayerCommand?
    /// Set when a reviewed expiry passed and the confirmation now shows new limits.
    private(set) var grantReviewNote: String?

    var handleDraft = ""
    var friendDraft = ""
    var resourceDraft = MultiplayerResourceDraft()
    var grantDraft = MultiplayerGrantDraft()
    let credentialEntry: MultiplayerSecretEntry

    let usesFixtureHelper: Bool
    let setupFailure: MultiplayerFailure?

    private let client: MultiplayerClient?
    private let steadyPoll: Duration
    private let fastPoll: Duration
    private let directoryExists: (String) -> Bool
    private let clock: () -> Date
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var actionTask: Task<Void, Never>?
    @ObservationIgnored private var lookupTask: Task<Void, Never>?
    @ObservationIgnored private var refreshToken = 0
    @ObservationIgnored private var lookupToken = 0

    init(client: MultiplayerClient?,
         setupFailure: MultiplayerFailure? = nil,
         usesFixtureHelper: Bool = false,
         steadyPoll: Duration = .seconds(15),
         fastPoll: Duration = .seconds(3),
         directoryExists: @escaping (String) -> Bool = MultiplayerSessionModel.isDirectory,
         now: @escaping () -> Date = { Date() }) {
        self.client = client
        self.setupFailure = setupFailure
        self.usesFixtureHelper = usesFixtureHelper
        self.steadyPoll = steadyPoll
        self.fastPoll = fastPoll
        self.directoryExists = directoryExists
        self.clock = now
        self.credentialEntry = MultiplayerSecretEntry()
    }

    nonisolated static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Derived values

    var presence: MultiplayerPresence {
        if let setupFailure { return .unavailable(setupFailure.message) }
        if let statusFailure { return .unavailable(statusFailure.message) }
        guard let status else { return isRefreshing ? .checking : .offline }
        if status.loginPending || (awaitingBrowser && !status.signedIn) { return .waitingForBrowser }
        if !status.signedIn {
            // A signed-out problem is recovered by signing in again, so it keeps the sign-in action.
            if !status.error.isEmpty { return .signInIncomplete(detail: Self.serviceText(status.error)) }
            return signInIncomplete ? .signInIncomplete(detail: nil) : .signedOut
        }
        if !status.error.isEmpty { return .serviceError(Self.serviceErrorText(status.error)) }
        if status.handle.isEmpty { return .needsHandle }
        return status.online ? .online(handle: status.handle) : .offline
    }

    /// The service's text when it reads as a plain sentence after redaction; otherwise nil.
    nonisolated static func serviceText(_ raw: String) -> String? {
        let text = MultiplayerText.clean(raw, limit: 160, redact: true)
        return text.isEmpty || text.contains("[redacted]") ? nil : text
    }

    /// The service's display-safe text, or a generic line.
    nonisolated static func serviceErrorText(_ raw: String) -> String {
        serviceText(raw) ?? "The network service reported a problem. Refresh to check again."
    }

    var isOnline: Bool {
        if case .online = presence { return true }
        return false
    }

    /// The handle shown beside the presence, only while online: never beside an error or setup step.
    var statusDetail: String? {
        guard case .online(let handle) = presence else { return nil }
        return handle
    }

    var isBusy: Bool { running != nil || savingCredentialFor != nil }
    var canRefresh: Bool { client != nil && !isBusy && !isRefreshing }

    var handleDraftProblem: String? {
        let handle = handleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return handle.isEmpty ? nil : MultiplayerInput.handleProblem(handle)
    }

    var canClaimHandle: Bool {
        !isBusy && MultiplayerInput.handleProblem(handleDraft.trimmingCharacters(in: .whitespacesAndNewlines)) == nil
    }

    /// The lookup for the handle now in the field. Editing the field retires an older result.
    var currentLookup: MultiplayerLookup {
        lookup.handle == friendDraft.trimmingCharacters(in: .whitespacesAndNewlines) ? lookup : .idle
    }

    var canLookUp: Bool {
        let handle = friendDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .searching = currentLookup { return false }
        return client != nil && MultiplayerInput.handleProblem(handle) == nil
    }

    var resourceTargetProblem: String? {
        resourceDraft.trimmedTarget.isEmpty ? nil : resourceDraft.targetProblem(directoryExists: directoryExists)
    }

    var resourceNameProblem: String? {
        resourceDraft.name.isEmpty ? nil : resourceDraft.nameProblem()
    }

    var canAddResource: Bool { !isBusy && resourceDraft.command(directoryExists: directoryExists) != nil }

    var grantResource: MultiplayerResource? {
        status?.resources.first { $0.id == grantDraft.resourceID }
    }

    /// The current time, from the injected clock.
    func currentDate() -> Date { clock() }

    /// The draft as a command with limits measured from `now`, while everything it names exists.
    func grantCommand(at now: Date) -> MultiplayerCommand? {
        guard let status, let resource = grantResource,
              status.friends.contains(where: { $0.handle == grantDraft.handle }),
              resource.actions.contains(grantDraft.capability),
              let limits = grantDraft.limits(now: now)
        else { return nil }
        return .grant(handle: grantDraft.handle, kind: resource.kind, resourceID: resource.id,
                      resourceName: resource.name, capability: grantDraft.capability, limits: limits)
    }

    var canReviewGrant: Bool { !isBusy && grantCommand(at: clock()) != nil }

    var grantUsesProblem: String? { grantDraft.usesProblem?.message }
    var grantExpiryProblem: String? { grantDraft.expiryProblem(now: clock())?.message }

    /// The range the custom expiry picker offers.
    var customExpiryRange: ClosedRange<Date> {
        let now = clock()
        return now.addingTimeInterval(MultiplayerGrantLimits.minimumLead + 60)
            ... now.addingTimeInterval(MultiplayerGrantLimits.maximumHorizon)
    }

    /// The friend, resource and action of a reviewed grant still exist in the latest status.
    private func stillGrantable(_ command: MultiplayerCommand) -> Bool {
        guard case .grant(let handle, _, let resourceID, _, let capability, _) = command, let status else { return false }
        return status.friends.contains { $0.handle == handle }
            && status.resources.contains { $0.id == resourceID && $0.actions.contains(capability) }
    }

    func resourceName(for id: String) -> String {
        status?.resources.first { $0.id == id }?.name ?? id
    }

    var canSignOut: Bool { setupFailure == nil && statusFailure == nil && status?.signedIn == true }

    /// Only your own enrolled repositories take a GitHub token; shared resources never do.
    static func takesCredential(_ resource: MultiplayerResource) -> Bool {
        resource.kind == MultiplayerResourceKind.repo.rawValue
    }

    /// The repository the token editor was opened for, while it is still yours and online.
    var credentialResource: MultiplayerResource? {
        guard isOnline, case .repoCredential(let id) = route else { return nil }
        return status?.resources.first { $0.id == id && Self.takesCredential($0) }
    }

    var credentialProblem: String? {
        let token = credentialEntry.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : MultiplayerCredential.problem(token)
    }

    var canSaveCredential: Bool {
        !isBusy && credentialResource != nil
            && MultiplayerCredential.problem(credentialEntry.value.trimmingCharacters(in: .whitespacesAndNewlines)) == nil
    }

    // MARK: - Panel lifetime

    /// A panel became visible. The first viewer starts the status poll.
    func open() {
        viewers += 1
        guard viewers == 1, client != nil else { return }
        pollTask?.cancel()
        let first = tick()
        pollTask = Task { [weak self] in
            var interval = first
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let next = self?.tick() else { return }
                interval = next
            }
        }
    }

    /// A panel closed. The last viewer stops the poll and every helper call it started.
    func close() {
        guard viewers > 0 else { return }
        viewers -= 1
        guard viewers == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
        cancelRefresh()
        cancelLookup()
        actionTask?.cancel()    // its own completion records the unconfirmed outcome
        credentialEntry.clear()
        if case .repoCredential = route { route = .home }
        // A sign-in in progress is re-read on reopen, so the service decides what is shown first:
        // the stale status goes, and only the fact that we were waiting is kept.
        if awaitingBrowser || status?.loginPending == true {
            awaitingBrowser = true
            status = nil
        }
    }

    /// One poll step. Returns the wait before the next.
    private func tick() -> Duration {
        if !isBusy, lookupTask == nil, route == .home { refresh() }
        return awaitingBrowser || status?.loginPending == true ? fastPoll : steadyPoll
    }

    // MARK: - Status

    @discardableResult
    func refresh() -> Task<Void, Never>? {
        guard let client, !isBusy, !isRefreshing else { return nil }
        refreshToken &+= 1
        let token = refreshToken
        isRefreshing = true
        let task = Task {
            let result: Result<MultiplayerStatus, MultiplayerFailure>
            do { result = .success(try await client.status()) } catch { result = .failure(.from(error)) }
            self.finishRefresh(result, token: token)
        }
        refreshTask = task
        return task
    }

    private func finishRefresh(_ result: Result<MultiplayerStatus, MultiplayerFailure>, token: Int) {
        guard token == refreshToken else { return }    // superseded by a mutation or a close
        isRefreshing = false
        refreshTask = nil
        switch result {
        case .success(let next):
            // The service is authoritative: a sign-in we were waiting on that is no longer pending
            // either finished (signed in) or failed (still signed out).
            let wasWaiting = awaitingBrowser || status?.loginPending == true
            if !next.loginPending, wasWaiting {
                signInIncomplete = !next.signedIn && next.error.isEmpty
            } else if next.loginPending || next.signedIn {
                signInIncomplete = false
            }
            awaitingBrowser = false
            status = next
            statusFailure = nil
            reconcileRoute()
        case .failure(.cancelled):
            break
        case .failure(let failure):
            status = nil
            statusFailure = failure
            credentialEntry.clear()
            route = .home
        }
    }

    private func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        if isRefreshing {
            refreshToken &+= 1
            isRefreshing = false
        }
    }

    /// Keeps an editor or confirmation only while what it refers to still exists.
    private func reconcileRoute() {
        guard isOnline else { return go(.home) }
        switch route {
        case .confirmGrant where !(reviewedGrant.map { stillGrantable($0) } ?? false):
            go(.grant)
        case .confirmRevoke(let grant) where !(status?.grants.contains(grant) ?? false):
            go(.home)
        case .repoCredential where credentialResource == nil:
            go(.home)
        default:
            break
        }
    }

    // MARK: - Commands

    @discardableResult
    func perform(_ command: MultiplayerCommand) -> Task<Void, Never>? {
        guard let client, !isBusy else { return nil }
        cancelRefresh()
        running = command
        actionFailure = nil
        credentialFailure = nil
        grantReviewNote = nil
        notice = nil
        let task = Task {
            var failure: MultiplayerFailure?
            do { try await client.perform(command) } catch { failure = .from(error) }
            self.finishAction(command, failure: failure)
        }
        actionTask = task
        return task
    }

    private func finishAction(_ command: MultiplayerCommand, failure: MultiplayerFailure?) {
        running = nil
        actionTask = nil
        if let failure {
            actionFailure = MultiplayerActionFailure(command: command, failure: failure)
            return
        }
        notice = command.confirmation
        switch command {
        case .login:
            awaitingBrowser = true
            signInIncomplete = false
        case .logout:
            awaitingBrowser = false
            signInIncomplete = false
            friendDraft = ""
            lookup = .idle
            grantDraft = MultiplayerGrantDraft()
            go(.home)
        case .claimHandle:
            handleDraft = ""
        case .sendRequest:
            friendDraft = ""
            lookup = .idle
            go(.home)
        case .accept:
            break
        case .grant:
            grantDraft = MultiplayerGrantDraft()
            go(.home)
        case .revoke:
            go(.home)
        case .addResource:
            resourceDraft = MultiplayerResourceDraft()
            go(.home)
        }
        if viewers > 0 { refresh() }
    }

    /// Re-sends a refused command, or reads status when the outcome is unknown. A refused grant is
    /// re-sent only with its reviewed limits; once its expiry has passed the owner reviews again.
    func retryAction() {
        guard let failed = actionFailure, failed.failure.canRetry else { return }
        if failed.failure.outcomeUnknown {
            actionFailure = nil
            refresh()
            return
        }
        if case .grant(_, _, _, _, _, let limits) = failed.command, !limits.isLive(at: clock()) {
            actionFailure = nil
            if route == .confirmGrant { reviewAgain() }
            return
        }
        actionFailure = nil
        perform(failed.command)
    }

    func dismissNotice() { notice = nil }
    func dismissFailure() {
        actionFailure = nil
        credentialFailure = nil
    }

    // MARK: - Repository credential

    /// Opens the token editor for one of your own repositories, chosen explicitly by its row.
    func startCredential(resourceID: String) {
        guard isOnline, !isBusy,
              status?.resources.contains(where: { $0.id == resourceID && Self.takesCredential($0) }) == true
        else { return }
        credentialFailure = nil
        go(.repoCredential(resourceID: resourceID))
    }

    /// Sends the entry's token once and clears the entry before the helper answers. A failure keeps
    /// only the repository's name; the owner re-enters the token rather than it being retried.
    @discardableResult
    func saveCredential() -> Task<Void, Never>? {
        let token = credentialEntry.value.trimmingCharacters(in: .whitespacesAndNewlines)
        credentialEntry.clear()
        guard let client, !isBusy, let resource = credentialResource,
              MultiplayerCredential.problem(token) == nil
        else { return nil }
        cancelRefresh()
        go(.home)
        actionFailure = nil
        credentialFailure = nil
        notice = nil
        savingCredentialFor = resource.name
        let task = Task {
            var failure: MultiplayerFailure?
            do { try await client.saveRepoCredential(resourceID: resource.id, token: token) } catch { failure = .from(error) }
            self.finishCredential(resourceID: resource.id, name: resource.name, failure: failure)
        }
        actionTask = task
        return task
    }

    private func finishCredential(resourceID: String, name: String, failure: MultiplayerFailure?) {
        savingCredentialFor = nil
        actionTask = nil
        if let failure {
            credentialFailure = MultiplayerCredentialFailure(resourceID: resourceID, resourceName: name, failure: failure)
        } else {
            notice = "Saved the GitHub token for \(name.multiplayerDisplay)."
        }
        if viewers > 0 { refresh() }
    }

    /// "Enter again" after an unconfirmed or refused save: reopens the empty editor.
    func reenterCredential() {
        guard let failed = credentialFailure, failed.failure.canRetry else { return }
        startCredential(resourceID: failed.resourceID)
    }

    // MARK: - Intents

    func go(_ next: MultiplayerRoute) {
        guard route != next else { return }
        credentialEntry.clear()    // leaving or switching the token editor drops what was typed
        if next != .confirmGrant { reviewedGrant = nil }    // a review is never reused after leaving it
        grantReviewNote = nil
        route = next
        actionFailure = nil
    }

    func signIn() { perform(.login) }
    func signOut() { perform(.logout) }

    func claimHandle() {
        let handle = handleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MultiplayerInput.handleProblem(handle) == nil else { return }
        perform(.claimHandle(handle))
    }

    func startAddFriend() {
        go(.addFriend)
    }

    /// Explicit exact-handle lookup. Nothing is sent to the person.
    @discardableResult
    func lookUpFriend() -> Task<Void, Never>? {
        let handle = friendDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, canLookUp else { return nil }
        cancelLookup()
        lookupToken &+= 1
        let token = lookupToken
        lookup = .searching(handle)
        let task = Task {
            let result: Result<String, MultiplayerFailure>
            do { result = .success(try await client.lookUp(handle: handle)) } catch { result = .failure(.from(error)) }
            self.finishLookup(result, handle: handle, token: token)
        }
        lookupTask = task
        return task
    }

    private func finishLookup(_ result: Result<String, MultiplayerFailure>, handle: String, token: Int) {
        guard token == lookupToken else { return }
        lookupTask = nil
        switch result {
        case .success(let found) where found == handle:
            lookup = .found(found)
        case .success:
            lookup = .failed(handle: handle, message: "The network matched a different handle, so nothing was sent. Check the exact spelling.")
        case .failure(.cancelled):
            lookup = .idle
        case .failure(let failure):
            lookup = .failed(handle: handle, message: failure.message)
        }
    }

    private func cancelLookup() {
        lookupTask?.cancel()
        lookupTask = nil
        lookupToken &+= 1
        if case .searching = lookup { lookup = .idle }
    }

    func sendFriendRequest() {
        guard case .found(let handle) = currentLookup else { return }
        perform(.sendRequest(handle: handle))
    }

    func accept(_ request: MultiplayerIncoming) {
        perform(.accept(requestID: request.id, handle: request.handle))
    }

    func startAddResource() {
        go(.addResource)
    }

    func addResource() {
        guard let command = resourceDraft.command(directoryExists: directoryExists) else { return }
        perform(command)
    }

    /// Opens the share form, preselecting what the developer chose and any single option.
    func startGrant(handle: String? = nil, resourceID: String? = nil) {
        guard let status else { return }
        var draft = MultiplayerGrantDraft()
        draft.handle = handle ?? (status.friends.count == 1 ? status.friends[0].handle : "")
        draft.resourceID = resourceID ?? (status.resources.count == 1 ? status.resources[0].id : "")
        draft.customExpiry = MultiplayerGrantDraft.seedExpiry(for: draft.expiry, now: clock())
        grantDraft = draft
        reconcileGrantCapability()
        go(.grant)
    }

    /// Switching to a custom time starts it at the end of the preset the owner had chosen.
    func grantExpiryChanged(from previous: MultiplayerGrantExpiry) {
        guard grantDraft.expiry == .custom, previous != .custom else { return }
        grantDraft.customExpiry = MultiplayerGrantDraft.seedExpiry(for: previous, now: clock())
    }

    /// Keeps the chosen action within what the chosen resource allows.
    func reconcileGrantCapability() {
        guard let resource = grantResource else {
            grantDraft.capability = ""
            return
        }
        if !resource.actions.contains(grantDraft.capability) {
            grantDraft.capability = resource.actions.count == 1 ? resource.actions[0] : ""
        }
    }

    /// Fixes the limits as of now. The confirmation shows, and Grant access sends, this command.
    func reviewGrant() {
        guard !isBusy, let command = grantCommand(at: clock()) else { return }
        reviewedGrant = command
        go(.confirmGrant)
    }

    /// Sends the reviewed grant unchanged, or, if its expiry has passed, sends nothing and asks the
    /// owner to review fresh limits.
    func confirmGrant() {
        guard route == .confirmGrant, let reviewed = reviewedGrant, stillGrantable(reviewed),
              case .grant(_, _, _, _, _, let limits) = reviewed
        else { return }
        guard limits.isLive(at: clock()) else { return reviewAgain() }
        perform(reviewed)
    }

    /// Replaces a lapsed review with limits measured from now, or returns to the editor when a
    /// custom time has itself passed. Nothing is sent either way.
    private func reviewAgain() {
        guard let command = grantCommand(at: clock()) else {
            go(.grant)
            grantReviewNote = "The chosen expiry passed before access was granted, so nothing was sent. Choose a new time."
            return
        }
        reviewedGrant = command
        grantReviewNote = "The reviewed expiry passed before access was granted, so nothing was sent. Check the new limits and grant again."
    }

    func askRevoke(_ grant: MultiplayerGrant) {
        go(.confirmRevoke(grant))
    }

    func confirmRevoke() {
        guard case .confirmRevoke(let grant) = route else { return }
        perform(.revoke(grantID: grant.id, handle: grant.handle,
                        resourceName: resourceName(for: grant.resource), capability: grant.capability))
    }

    // MARK: - Testing support

    /// Waits until no helper call started by this model is in flight.
    func settle() async {
        while let task = actionTask ?? refreshTask ?? lookupTask {
            await task.value
        }
    }
}
