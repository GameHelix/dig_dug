import Foundation

/// A repository on GitHub, as owner/name: what a course's project keeps (project.github_repo)
/// and its GitHub lessons check.
public struct GitHubRepo: Hashable, Sendable, CustomStringConvertible {
    public let owner: String
    public let name: String

    /// The owner is letters, digits and single hyphens, neither first nor last, at most 39
    /// characters; the name is letters, digits, '.', '_' and '-', at most 100, and not . or ..
    /// (the schema's CHECK on project.github_repo).
    public init?(owner: String, name: String) {
        guard GitHubRepo.isOwner(owner), GitHubRepo.isName(name) else { return nil }
        self.owner = owner
        self.name = name
    }

    /// What a learner pastes: owner/name, the repository's address
    /// (https://github.com/owner/name, with or without .git or a trailing slash, or a page
    /// inside it) or its SSH clone address (git@github.com:owner/name.git).
    public init?(parsing text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if let colon = rest.range(of: "git@github.com:", options: [.anchored, .caseInsensitive]) {
            rest = rest[colon.upperBound...]
        } else if rest.range(of: "://", options: .literal) != nil {
            guard let url = URL(string: String(rest)), let scheme = url.scheme?.lowercased(), ["https", "http", "ssh", "git"].contains(scheme),
                  let host = url.host()?.lowercased(), host == "github.com" || host == "www.github.com" else { return nil }
            rest = Substring(url.path(percentEncoded: false))
        } else if let host = rest.range(of: "github.com/", options: [.anchored, .caseInsensitive])
                    ?? rest.range(of: "www.github.com/", options: [.anchored, .caseInsensitive]) {
            rest = rest[host.upperBound...]
        } else if rest.split(separator: "/", omittingEmptySubsequences: false).count > 2 && !rest.hasSuffix("/") {
            // Bare owner/name has one slash; more is a path without github.com in front.
            return nil
        }
        let parts = rest.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        var name = parts[1]
        if name.lowercased().hasSuffix(".git") { name = name.dropLast(4) }
        self.init(owner: String(parts[0]), name: String(name))
    }

    public var fullName: String { "\(owner)/\(name)" }
    public var description: String { fullName }

    /// The repository's page on GitHub.
    public var webURL: URL {
        var c = URLComponents()
        c.scheme = "https"
        c.host = "github.com"
        c.path = "/\(owner)/\(name)"
        return c.url ?? URL(fileURLWithPath: "/")
    }

    /// Whether GitHub accepts this as an account or organization name.
    public static func isOwner(_ s: String) -> Bool {
        guard (1...39).contains(s.count), s.first != "-", s.last != "-", !s.contains("--") else { return false }
        return s.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "-") }
    }

    /// Whether GitHub accepts this as a repository name.
    public static func isName(_ s: String) -> Bool {
        guard (1...100).contains(s.count), s != ".", s != ".." else { return false }
        return s.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "._-".unicodeScalars.contains($0)) }
    }
}
