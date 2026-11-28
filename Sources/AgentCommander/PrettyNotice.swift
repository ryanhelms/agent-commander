import Foundation

// PRETTY NOTICE (DESIGN.md, "Pretty transcript"; spec section H, "ACP `notice`")
// A provider may send a notice in the middle of a turn: a title and a severity. The service keeps
// one message per notice, at the event's own position, with the text `[ACP notice] <title>` and
// the provider's severity in `metadata.acp.noticeSeverity` when it is exactly `info`, `warning`
// or `error`. An older record, or one whose severity the service did not keep, has no such field.
//
//   Values          NoticeMark               what the message's reference says: the stated level
//   Feature layer   ActivityEvent            the row's label, ink and whether it folds
//
// Nothing is inferred. The mark is read only from a message whose ACP kind is exactly `notice`,
// and its level only from `noticeSeverity`. The title, the text, an address and any other
// record's fields never decide a level.

/// What the service's reference says about one provider notice.
struct NoticeMark: Equatable, Sendable {
    /// The provider's severity, exactly as the service kept it.
    enum Level: String, Equatable, Sendable {
        case info, warning, error
    }

    /// The ACP kind the service gives the message.
    static let kind = "notice"
    /// The marker the service writes before the title.
    static let marker = "[ACP notice]"

    /// Nil when the reference states no level, or one that is not exactly a `Level`: the notice
    /// is then shown without a severity.
    let level: Level?

    /// Nil unless the message is a notice: a kind of exactly `notice`, from a role that is
    /// neither the developer nor the agent.
    init?(message: AGUIMessage, acp: [String: AGUIValue]) {
        guard message.role != "user", message.role != "assistant",
              acp["kind"]?.stringValue == Self.kind else { return nil }
        level = acp["noticeSeverity"]?.stringValue.flatMap(Level.init(rawValue:))
    }

    init(level: Level?) {
        self.level = level
    }

    /// The notice joins the group of finished lines beside it: only one the provider sent as
    /// `info`. A warning, an error and a notice with no level stay in the open. Read from the
    /// level alone, so choosing what stays needs no title.
    var folds: Bool { level == .info }

    /// The title as Pretty shows it: the message's text without the service's marker. A title
    /// that starts with a word such as "Notice" or "Warning" keeps it. With `hidesSecrets` (the
    /// transcript setting, `ToolDetailStore.hidesSecrets`), a value that looks like a secret is
    /// hidden as `SecretValues.masked(prose:)` hides it; the record keeps the title as sent.
    static func title(in body: String, hidesSecrets: Bool = false) -> String {
        let title = body.hasPrefix(marker)
            ? body.dropFirst(marker.count).trimmingCharacters(in: .whitespacesAndNewlines) : body
        return hidesSecrets ? SecretValues.masked(prose: title).text : title
    }
}

extension ActivityEvent {
    /// The row of a provider notice, by the level its reference states.
    ///
    /// - `warning`, `error`: the attention row, labelled "Warning" or "Error", never folded.
    /// - `info`: the quiet line "Notice", folded with the session updates beside it.
    /// - no level: the row "Notice" in secondary ink, never folded. It names no severity.
    ///
    /// The title is prepared once, here, so the row, the folded line and VoiceOver read the same
    /// text: with `hidesSecrets`, the masked one.
    init(notice: NoticeMark, body: String, hidesSecrets: Bool = false) {
        let title = NoticeMark.title(in: body, hidesSecrets: hidesSecrets)
        switch notice.level {
        case .warning?:
            self.init(symbol: "exclamationmark.triangle", label: "Warning", detail: title, tone: .attention)
        case .error?:
            self.init(symbol: "exclamationmark.octagon", label: "Error", detail: title, tone: .attention)
        case .info?:
            self.init(symbol: "bell", label: "Notice", detail: title, tone: .quiet)
        case nil:
            self.init(symbol: "bell", label: "Notice", detail: title, tone: .quiet, folds: false)
        }
        assert(folds == notice.folds)
    }
}
