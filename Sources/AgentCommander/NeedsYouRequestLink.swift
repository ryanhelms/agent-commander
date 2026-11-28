import Foundation

/// Identifies a Needs You row. A link opens the review and carries no action or authority.
struct NeedsYouRequestLink: Equatable, Sendable {
    private static let scheme = "agentcommander"
    private static let host = "needs-you"
    private static let key = "request"

    let id: String

    init?(id: String) {
        guard !id.isEmpty, id.utf8.count <= 1_024,
              id == id.trimmingCharacters(in: .whitespacesAndNewlines),
              id.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        self.id = id
    }

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.scheme,
              components.percentEncodedHost?.lowercased() == Self.host,
              components.percentEncodedPath.isEmpty, components.user == nil,
              components.password == nil, components.port == nil, components.fragment == nil,
              let parameters = components.queryItems, parameters.count == 1,
              let request = parameters.first, request.name == Self.key,
              let id = request.value else { return nil }
        self.init(id: id)
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [URLQueryItem(name: Self.key, value: id)]
        // The scheme and host are constants. URLComponents encodes the validated ID as data.
        return components.url!
    }
}
