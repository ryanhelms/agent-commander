import Foundation
import UserNotifications

// FEATURE MODEL: the tray's social intents (design/COMMANDER-NETWORK-INCREMENT-2.md).
// MultiplayerModel owns the state; this file reads linked contacts, the feed, avatars and admin
// rights, and sends presence, profile, invite, membership and join. Rules it keeps:
// - Contacts, the feed, avatars and `me` are read quietly. A failed read never hides the server list.
// - A notification is posted only for an event that arrived after the first feed reply, and never
//   while presence is Do not disturb.
// - Only the profile fields the person changed are sent.
// - An invite link stands in for the person's own fingerprint check only when the certificate the
//   server presents matches the link's pin.

/// Posts one macOS notification. Tests substitute a recorder.
protocol MultiplayerNotifying: Sendable {
    func post(id: String, title: String, body: String) async
}

struct MultiplayerUserNotifier: MultiplayerNotifying {
    /// Notifications need a bundled app; a bare `swift run` binary has no notification centre.
    static func forThisProcess() -> MultiplayerUserNotifier? {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" ? MultiplayerUserNotifier() : nil
    }

    func post(id: String, title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

extension MultiplayerModel {
    static let activityLimit = 300
    static let notificationBurst = 3

    // MARK: - Quiet reads

    /// Reads contacts, the feed and any missing admin answers. Called after each server list.
    func refreshSocial() {
        guard let client, socialTask == nil else { return }
        let cursor = activityLoaded && !activityCursor.isEmpty ? activityCursor : nil
        let unanswered = servers.filter { $0.state == .online && $0.signedIn && me[$0.id] == nil }.map(\.id)
        socialTask = Task {
            if let next = try? await client.contacts() { self.applyContacts(next) }
            if let feed = try? await client.activity(after: cursor) { self.applyActivity(feed) }
            for id in unanswered where !Task.isCancelled {
                if let answer = try? await client.scoped(to: id).me() { self.me[id] = answer }
            }
            self.socialTask = nil
        }
    }

    func cancelSocial() {
        socialTask?.cancel()
        sideTasks.values.forEach { $0.cancel() }
    }

    func applyContacts(_ next: [MultiplayerContact]) {
        contacts = next
        for row in next.flatMap(\.rows) where row.hasAvatar {
            loadAvatar(server: row.server, handle: row.handle)
        }
    }

    /// Merges a feed reply and posts notifications for what is new since the last one.
    func applyActivity(_ feed: MultiplayerActivityFeed) {
        let known = Set(activity.map(\.id))
        let fresh = MultiplayerActivityEvent.newestFirst(feed.events.filter { !known.contains($0.id) })
        activity = Array(MultiplayerActivityEvent.newestFirst(feed.events + activity).prefix(Self.activityLimit))
        if !feed.cursor.isEmpty { activityCursor = feed.cursor }
        unseen = feed.unseen
        if activityLoaded, !isDoNotDisturb { notify(fresh) }
        activityLoaded = true
    }

    /// The person chose Do not disturb, here or as a server reports it.
    var isDoNotDisturb: Bool {
        presenceChoice == .dnd || servers.contains { $0.presence == .dnd }
    }

    private func notify(_ events: [MultiplayerActivityEvent]) {
        guard let notifier, !events.isEmpty else { return }
        var posts = events.prefix(Self.notificationBurst).map { event in
            (id: event.id, title: server(event.server)?.displayName ?? "Commander network", body: event.sentence)
        }
        if events.count > posts.count {
            posts.append((id: "more-\(events[0].id)", title: "Commander network",
                          body: "\(events.count - Self.notificationBurst) more new events"))
        }
        Task {
            for post in posts { await notifier.post(id: post.id, title: post.title, body: post.body) }
        }
    }

    /// Keeps the feed arriving while no panel is open, so new events can be notified.
    func startActivityWatch() {
        guard client != nil, notifier != nil, watchTask == nil else { return }
        let interval = steadyPoll * 2
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.viewers == 0 { self.refresh() }
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    // MARK: - Activity feed

    /// The feed under the two filters.
    var filteredActivity: [MultiplayerActivityEvent] {
        activity.filter { event in
            (activityServer == nil || event.server == activityServer)
                && (activityFriend == nil || event.actor == activityFriend)
        }
    }

    /// Everyone who appears in the feed, for the friend filter.
    var activityActors: [String] {
        Set(activity.map(\.actor)).filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Tells the device agent the person has seen the feed up to its latest event.
    @discardableResult
    func markActivitySeen() -> Task<Void, Never>? {
        guard let client, unseen > 0, !activityCursor.isEmpty else { return nil }
        let cursor = activityCursor
        let before = unseen
        unseen = 0
        return Task {
            do { try await client.markActivitySeen(cursor: cursor) } catch { if self.unseen == 0 { self.unseen = before } }
        }
    }

    // MARK: - Avatars and admin rights

    func avatar(server: String, handle: String) -> Data? {
        avatars[MultiplayerAvatarKey.make(server: server, handle: handle)].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Reads one avatar once. A failed read is remembered as no picture, so it isn't asked for on every poll.
    func loadAvatar(server: String, handle: String, again: Bool = false) {
        let key = MultiplayerAvatarKey.make(server: server, handle: handle)
        guard let client, sideTasks[key] == nil, again || avatars[key] == nil else { return }
        sideTasks[key] = Task {
            let image = try? await client.scoped(to: server).avatar(handle: handle)
            if !Task.isCancelled { self.avatars[key] = image?.data ?? Data() }
            self.sideTasks[key] = nil
        }
    }

    func refreshMe(_ id: String) {
        let key = "me:\(id)"
        guard let client, sideTasks[key] == nil, let server = server(id), server.state == .online, server.signedIn else { return }
        sideTasks[key] = Task {
            if let answer = try? await client.scoped(to: id).me() { self.me[id] = answer }
            self.sideTasks[key] = nil
        }
    }

    func isAdmin(_ id: String) -> Bool { me[id]?.admin == true }

    // MARK: - Presence

    /// The presence the first online server shows for this account.
    var shownPresence: MultiplayerPersonPresence? {
        servers.first { $0.state == .online && $0.signedIn && $0.presence != nil }?.presence
    }

    var presenceTitle: String {
        guard let shown = shownPresence else { return presenceChoice?.title ?? "Presence" }
        return presenceChoice == .auto ? "\(shown.title), auto" : shown.title
    }

    var canSetPresence: Bool {
        !isBusy && servers.contains { $0.state == .online && $0.signedIn }
    }

    /// Sets the same choice on every server the person is signed in to.
    @discardableResult
    func setPresence(_ choice: MultiplayerPresenceChoice) -> Task<Void, Never>? {
        let targets = servers.filter { $0.state == .online && $0.signedIn }
        guard !targets.isEmpty else { return nil }
        return act("Setting your presence to \(choice.title)…", failing: "Couldn’t set your presence.") { client in
            var last: MultiplayerPresenceReply?
            for server in targets { last = try await client.scoped(to: server.id).setPresence(choice) }
            self.presenceChoice = last?.auto == true ? .auto : choice
        }
    }

    // MARK: - Profile

    func startProfile(_ id: String) {
        guard let session = session(id), session.isOnline, let status = session.status else { return }
        profileDraft = MultiplayerProfileDraft(handle: status.handle, displayName: status.displayName,
                                               statusMessage: status.statusMessage, savedHandle: status.handle,
                                               savedDisplayName: status.displayName,
                                               savedStatusMessage: status.statusMessage)
        go(.profile(id))
        if status.hasAvatar { loadAvatar(server: id, handle: status.handle) }
    }

    /// The picture the profile editor shows: the picked one, or the saved one.
    func profileAvatar(_ id: String) -> Data? {
        switch profileDraft.avatar {
        case .replace(let encoded): encoded.image
        case .remove: nil
        case .keep: avatar(server: id, handle: profileDraft.savedHandle)
        }
    }

    /// Takes the bytes of a picked image file and readies them as the new avatar.
    func pickAvatar(_ file: Data) {
        guard let encoded = MultiplayerAvatarEncoder.encode(file) else {
            post(failure: "Commander can’t use that file as a picture. Choose a PNG or JPEG image.")
            return
        }
        post(failure: nil)
        profileDraft.avatar = .replace(encoded)
    }

    func removeAvatar() {
        guard case .profile(let id) = route else { return }
        profileDraft.avatar = avatar(server: id, handle: profileDraft.savedHandle) == nil ? .keep : .remove
    }

    var canSaveProfile: Bool { !isBusy && profileDraft.problem == nil && profileDraft.hasChanges }

    @discardableResult
    func saveProfile() -> Task<Void, Never>? {
        guard canSaveProfile, case .profile(let id) = route else { return nil }
        let draft = profileDraft
        return act("Saving your profile…", failing: "Couldn’t save your profile.", confirmation: "Profile saved.") { client in
            var avatar: String?
            switch draft.avatar {
            case .keep: avatar = nil
            case .replace(let encoded): avatar = encoded.dataURL
            case .remove: avatar = ""
            }
            try await client.scoped(to: id).setProfile(
                handle: draft.trimmedHandle == draft.savedHandle ? nil : draft.trimmedHandle,
                displayName: draft.trimmedDisplayName == draft.savedDisplayName ? nil : draft.trimmedDisplayName,
                statusMessage: draft.trimmedStatus == draft.savedStatusMessage ? nil : draft.trimmedStatus,
                avatar: avatar)
            let key = MultiplayerAvatarKey.make(server: id, handle: draft.trimmedHandle)
            switch draft.avatar {
            case .keep: self.avatars[key] = self.avatars[MultiplayerAvatarKey.make(server: id, handle: draft.savedHandle)]
            case .replace(let encoded): self.avatars[key] = encoded.image
            case .remove: self.avatars[key] = Data()
            }
            self.session(id)?.refresh()
            self.go(.server(id))
        }
    }

    // MARK: - Invites

    func startInvite(_ id: String) {
        guard server(id)?.state == .online else { return }
        inviteDraft = MultiplayerInviteDraft()
        go(.invite(id))
        refreshMe(id)
    }

    /// Unknown rights are left to the relay to refuse.
    func canInvite(_ id: String) -> Bool { me[id]?.canInvite ?? true }

    @discardableResult
    func createInvite() -> Task<Void, Never>? {
        guard case .invite(let id) = route, canInvite(id) else { return nil }
        let draft = inviteDraft
        return act("Creating an invite link…", failing: "Couldn’t create the invite.") { client in
            self.invite = try await client.scoped(to: id).createInvite(maxUses: draft.maxUses, ttlHours: draft.ttlHours)
        }
    }

    /// Opens an `agentcommander://join` link: the add-server form, filled in and already checking.
    @discardableResult
    func openInvite(_ text: String) -> Bool {
        guard let link = MultiplayerInviteLink.parse(text) else {
            post(failure: "Commander can’t read that invite link. Ask the person who sent it for a new one.")
            return false
        }
        let host = MultiplayerServerAddress.host(link.server).lowercased()
        if let saved = servers.first(where: { MultiplayerServerAddress.host($0.url).lowercased() == host }) {
            openServer(saved.id)
            post(notice: "\(saved.displayName) is already in your list.")
            return true
        }
        serverDraft = MultiplayerServerDraft(address: link.server, invite: link)
        go(.addServer)
        runProbe()
        return true
    }

    /// Adds the invite's server and starts sign-in with its code. The helper does both.
    func join(_ link: MultiplayerInviteLink) -> Task<Void, Never>? {
        act("Joining \(MultiplayerServerAddress.host(link.server).multiplayerDisplay)…", failing: "Couldn’t join the server.") { client in
            let saved = try await client.join(link: link.raw)
            self.merge(saved)
            let request = link.from.isEmpty ? "" : " A friend request goes to \(link.from.multiplayerDisplay) once you’re signed in."
            self.post(notice: "Added \(saved.displayName). Finish signing in in your browser.\(request)")
            self.serverDraft = MultiplayerServerDraft()
            self.go(.home)
        }
    }

    // MARK: - Membership

    func startMembership(_ id: String) {
        guard isAdmin(id) else { return }
        membershipDraft = MultiplayerMembershipDraft()
        go(.membership(id))
        loadMembership()
    }

    func loadMembership() {
        guard let client, case .membership(let id) = route else { return }
        membershipTask?.cancel()
        membershipToken &+= 1
        let token = membershipToken
        membership = .loading
        membershipTask = Task {
            let result: Result<MultiplayerMembership, MultiplayerFailure>
            do { result = .success(try await client.scoped(to: id).membership()) } catch { result = .failure(.from(error)) }
            // A newer read, or a page change, owns the state now.
            guard token == self.membershipToken else { return }
            self.membershipTask = nil
            guard self.route == .membership(id) else { return }
            switch result {
            case .success(let current):
                self.membership = .loaded(current)
                self.membershipDraft = MultiplayerMembershipDraft(current)
            case .failure(let failure):
                self.membership = .failed(failure == .cancelled ? "The read was stopped. Try again." : failure.message)
            }
        }
    }

    var canSaveMembership: Bool {
        guard !isBusy, let current = membership.membership, membershipDraft.problem == nil else { return false }
        return membershipDraft.differs(from: current)
    }

    @discardableResult
    func saveMembership() -> Task<Void, Never>? {
        guard canSaveMembership, case .membership(let id) = route else { return nil }
        let draft = membershipDraft
        return act("Saving membership…", failing: "Couldn’t save membership.", confirmation: "Membership saved.") { client in
            let saved = try await client.scoped(to: id).setMembership(mode: draft.mode, allowedEmails: draft.allowedList,
                                                                      admins: draft.adminList)
            self.membership = .loaded(saved)
            self.membershipDraft = MultiplayerMembershipDraft(saved)
            self.me[id] = nil
        }
    }
}
