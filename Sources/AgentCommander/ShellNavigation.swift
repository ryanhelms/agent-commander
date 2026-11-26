import Foundation

// ATOMIC LEVEL: Values (main-window shell).
// `CommanderNavigation` is the one navigation model of the main window. It lists every place once
// and arranges the same places two ways: as groups, for a list sidebar, and as modes, for a rail
// with a context list. The three navigation templates (grouped sidebar, mode rail, Needs you
// first) read this value and emit `CommanderNavigationAction`s. A page never sees the template.
//
//   CommanderPlace        one destination: id, title, mark, count, hot
//   CommanderPlaceGroup   a titled run of places
//   CommanderMode         a rail cell and the sections of its context list
//   CommanderInbox        which place is the combined inbox and the places it stands in for
//   CommanderProfile      the person and the presence their friends see
//   CommanderServerHealth how many servers answer, for the toolbar readout and the Servers place

/// One destination in the window.
struct CommanderPlace: Identifiable, Equatable, Sendable {
    enum Mark: Equatable, Sendable {
        case symbol(String)
        /// A project or workspace: one letter on a square mark.
        case letter(String)
    }

    let id: String
    var title: String
    var mark: Mark
    /// How many things wait at this place. Zero shows nothing.
    var count = 0
    /// A figure shown in place of the count, such as "2/3".
    var figure: String? = nil
    /// The count needs the person: it is drawn filled in the attention role.
    var isHot = false
    /// A page of a larger place. Only a template with a context list shows it as a row.
    var isDetail = false
    /// The count's noun, for VoiceOver: "3 waiting".
    var countNoun = "waiting"

    /// What sits at the row's trailing edge, if anything.
    var badge: String? { figure ?? (count > 0 ? "\(count)" : nil) }

    /// What VoiceOver says for the row.
    var spoken: String {
        if let figure { return "\(title), \(figure.replacingOccurrences(of: "/", with: " of "))" }
        return count > 0 ? "\(title), \(count) \(countNoun)" : title
    }
}

/// A titled run of places.
struct CommanderPlaceGroup: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var placeIDs: [String]
    /// A list sidebar may fold this group away.
    var isCollapsible = false
}

/// One cell of the mode rail and the sections its context list shows.
struct CommanderMode: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var symbol: String
    var sections: [CommanderPlaceGroup]
    /// Pinned to the foot of the rail (Settings).
    var isTrailing = false

    var placeIDs: [String] { sections.flatMap(\.placeIDs) }
}

/// The combined inbox: the place that opens it, and the separate queues it stands in for.
struct CommanderInbox: Equatable, Sendable {
    var placeID: String
    /// Places whose requests the inbox already lists. A template that pins the inbox leaves them out.
    var absorbs: [String] = []
    /// One line under the pinned inbox, such as "2 from your workers, 4 from the network".
    var summary: String? = nil
}

/// The person at this Mac.
struct CommanderProfile: Equatable, Sendable {
    var name: String
    var handle: String
    /// The presence the servers show now. Nil while signed out.
    var presence: MultiplayerPersonPresence?
    /// The person's choice. Nil until the device agent has said which is in force.
    var choice: MultiplayerPresenceChoice?

    /// The word beside the presence lamp.
    var presenceTitle: String {
        switch presence {
        case .online: "Online"
        case .away: "Away"
        case .busy: "Busy"
        case .dnd: "Do not disturb"
        case .offline: "Offline"
        case .unknown: "Unknown"
        case nil: "Signed out"
        }
    }
}

/// How many of the person's servers answer.
struct CommanderServerHealth: Equatable, Sendable {
    var online: Int
    var total: Int

    var figure: String { "\(online)/\(total)" }
    var spoken: String { "\(online) of \(total) online" }

    /// All answering is working, some is attention, none is failure. No servers is neutral.
    var tone: Tone {
        if total == 0 { return .neutral }
        if online == total { return .working }
        return online == 0 ? .failure : .attention
    }
}

/// What a navigation template can ask for.
enum CommanderNavigationAction: Equatable, Sendable {
    case select(String)
    case selectMode(String)
    case toggleGroup(String)
    case setPresence(MultiplayerPresenceChoice)
}

struct CommanderNavigation: Equatable, Sendable {
    /// A place as a template draws it: the place, whether it is selected, and its ⌘-number.
    struct Item: Identifiable, Equatable, Sendable {
        let place: CommanderPlace
        let isSelected: Bool
        /// 1 to 9 when the place has a ⌘-number shortcut.
        let shortcut: Int?

        var id: String { place.id }
    }

    /// A group as a list template draws it.
    struct Section: Identifiable, Equatable, Sendable {
        let group: CommanderPlaceGroup
        let items: [Item]
        let isCollapsed: Bool
        /// The hot counts inside, shown beside the heading while the group is folded.
        let hotCount: Int

        var id: String { group.id }
    }

    /// A mode as the rail draws it.
    struct ModeItem: Identifiable, Equatable, Sendable {
        let mode: CommanderMode
        let isSelected: Bool
        let shortcut: Int?
        /// The hot counts of the mode's places.
        let hotCount: Int

        var id: String { mode.id }
    }

    /// Every place, once.
    var places: [CommanderPlace]
    var inbox: CommanderInbox? = nil
    /// The places as a list sidebar groups them.
    var groups: [CommanderPlaceGroup]
    /// The same places as a mode rail groups them.
    var modes: [CommanderMode] = []
    /// Places pinned to the foot of a list sidebar.
    var footer: [String] = []
    var profile: CommanderProfile? = nil
    var selection: String
    var collapsed: Set<String> = []

    // MARK: Lookups

    func place(_ id: String) -> CommanderPlace? { places.first { $0.id == id } }

    var selectedPlace: CommanderPlace? { place(selection) }

    /// The mode whose context list holds the selected place. The first mode when none does.
    var selectedModeID: String? {
        (modes.first { $0.placeIDs.contains(selection) } ?? modes.first)?.id
    }

    /// Where the selected place sits, for a breadcrumb: its group's title, then its own.
    var crumbs: [String] {
        guard let place = selectedPlace else { return [] }
        let group = groups.first { $0.placeIDs.contains(selection) }
            ?? modes.flatMap(\.sections).first { $0.placeIDs.contains(selection) }
        return (group.map { [$0.title] } ?? []) + [place.title]
    }

    // MARK: Arrangements

    /// The groups of a list sidebar, without detail places. `pinningInbox` also leaves out the
    /// inbox place and the places it stands in for, because the template draws the inbox itself.
    /// ⌘-numbers run down the visible rows, after the pinned inbox when there is one. A template
    /// whose groups don't fold passes `folding: false` and gets every group open.
    func sections(pinningInbox: Bool, folding: Bool = true) -> [Section] {
        let hidden = pinningInbox ? Set(inbox.map { [$0.placeID] + $0.absorbs } ?? []) : []
        var number = pinningInbox && inbox != nil ? 1 : 0
        var result: [Section] = []
        for group in groups {
            let visible = group.placeIDs.compactMap(place).filter { !$0.isDetail && !hidden.contains($0.id) }
            guard !visible.isEmpty else { continue }
            let isCollapsed = folding && group.isCollapsible && collapsed.contains(group.id)
            let items = visible.map { place -> Item in
                number += 1
                return Item(place: place, isSelected: place.id == selection, shortcut: number <= 9 ? number : nil)
            }
            var shown = group
            if !folding { shown.isCollapsible = false }
            result.append(Section(group: shown, items: items, isCollapsed: isCollapsed, hotCount: hotCount(of: items.map(\.id))))
        }
        return result
    }

    /// The pinned inbox row. It is selected while its own place or one it stands in for is showing.
    var inboxItem: Item? {
        guard let inbox, let place = place(inbox.placeID) else { return nil }
        let isSelected = selection == inbox.placeID || inbox.absorbs.contains(selection)
        return Item(place: place, isSelected: isSelected, shortcut: 1)
    }

    /// The rows at the foot of a list sidebar. They carry no ⌘-number.
    var footerItems: [Item] {
        footer.compactMap(place).map { Item(place: $0, isSelected: $0.id == selection, shortcut: nil) }
    }

    /// The hot counts among the given places, counting each request once: where the inbox is one
    /// of them, the queues it stands in for are left out.
    func hotCount(of ids: [String]) -> Int {
        let covered = inbox.map { ids.contains($0.placeID) ? Set($0.absorbs) : [] } ?? []
        return ids.filter { !covered.contains($0) }.compactMap(place).filter(\.isHot).reduce(0) { $0 + $1.count }
    }

    /// The rail's cells. ⌘-numbers run down the rail, trailing modes last.
    var modeItems: [ModeItem] {
        let selected = selectedModeID
        let ordered = modes.filter { !$0.isTrailing } + modes.filter(\.isTrailing)
        return ordered.enumerated().map { index, mode in
            ModeItem(mode: mode, isSelected: mode.id == selected, shortcut: index < 9 ? index + 1 : nil,
                     hotCount: hotCount(of: mode.placeIDs))
        }
    }

    /// The context list of the selected mode: every place of the mode, detail places included.
    var contextSections: [Section] {
        guard let mode = modes.first(where: { $0.id == selectedModeID }) else { return [] }
        return mode.sections.compactMap { group in
            let items = group.placeIDs.compactMap(place).map {
                Item(place: $0, isSelected: $0.id == selection, shortcut: nil)
            }
            return items.isEmpty ? nil : Section(group: group, items: items, isCollapsed: false, hotCount: hotCount(of: items.map(\.id)))
        }
    }

    // MARK: Actions

    /// Applies one action. An unknown place, mode or group changes nothing.
    mutating func apply(_ action: CommanderNavigationAction) {
        switch action {
        case .select(let id):
            guard place(id) != nil else { return }
            selection = id
            // A folded group opens when a place inside it is chosen another way.
            if let group = groups.first(where: { $0.placeIDs.contains(id) }) { collapsed.remove(group.id) }
        case .selectMode(let id):
            guard let mode = modes.first(where: { $0.id == id }), selectedModeID != id,
                  let first = mode.placeIDs.first(where: { place($0) != nil }) else { return }
            selection = first
        case .toggleGroup(let id):
            guard groups.contains(where: { $0.id == id && $0.isCollapsible }) else { return }
            if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        case .setPresence(let choice):
            guard profile != nil else { return }
            profile?.choice = choice
            // The servers report what they show. Until they answer, show the choice itself.
            switch choice {
            case .auto, .online: profile?.presence = .online
            case .away: profile?.presence = .away
            case .busy: profile?.presence = .busy
            case .dnd: profile?.presence = .dnd
            }
        }
    }
}
