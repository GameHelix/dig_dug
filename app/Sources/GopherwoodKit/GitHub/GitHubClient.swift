import Foundation
import os

/// A token for GitHub's API, from the GitHub CLI's sign-in (GitHubCLI). It lives for one check
/// and is never stored, logged or shown: it prints and reflects as hidden, and GitHubClient
/// sends it to api.github.com only.
public struct GitHubToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let value: String

    public init(_ value: String) { self.value = value }

    public var description: String { "GitHubToken(hidden)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Why GitHub gave no answer about your repository. Each one stops a check run: it is about
/// the way to GitHub, not about what the repository holds.
public enum GitHubError: Error, Equatable, Sendable, LocalizedError {
    /// The network failed or timed out.
    case unreachable(String)
    /// The hourly limit on requests is used up until `resetsAt`.
    case rateLimited(resetsAt: Date?, signedIn: Bool)
    /// A secondary limit: GitHub asks to wait `retryAfter` seconds.
    case slowDown(retryAfter: Int?)
    /// GitHub refused the GitHub CLI's token: it expired or was revoked.
    case badCredentials
    /// GitHub itself failed (a 5xx status).
    case server(status: Int)
    /// An answer that could not be read.
    case unreadable(String)
    case tooManyRedirects
    /// GitHub turned down a change, such as a repository name already taken; its message.
    case refused(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unreachable(let detail):
            "GitHub can't be reached. \(detail)"
        case .rateLimited(let resetsAt, let signedIn):
            "GitHub's limit on requests is used up " + (resetsAt.map { "until \($0.formatted(date: .omitted, time: .shortened))." } ?? "for now.")
                + (signedIn ? "" : " Signing in with `gh auth login` in Terminal raises the limit.")
        case .slowDown(let seconds):
            "GitHub asks to slow down: check again in " + (seconds.map { $0 <= 1 ? "a second." : "\($0) seconds." } ?? "a minute.")
        case .badCredentials:
            "GitHub refused the GitHub CLI's sign-in. Run `gh auth login` in Terminal, then check again."
        case .server(let status):
            "GitHub answered with an error (\(status)). Check again in a moment."
        case .unreadable(let detail):
            "GitHub's answer could not be read: \(detail)"
        case .tooManyRedirects:
            "GitHub redirected too many times."
        case .refused(let message):
            message
        case .cancelled:
            "Stopped."
        }
    }
}

/// An answer from GitHub.
public struct GitHubResponse: Sendable {
    public let status: Int
    public let url: URL
    /// The header fields, names lowercased.
    let headers: [String: String]
    public let body: Data

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// The body as JSON of the given shape, keys in snake case.
    func decode<T: Decodable>(_ type: T.Type) throws(GitHubError) -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: body)
        } catch {
            throw .unreadable("\(T.self) from \(url.path()): \(error.localizedDescription)")
        }
    }

    /// GitHub's message in an error answer, if it has one.
    var message: String? {
        struct Message: Decodable { let message: String? }
        return (try? JSONDecoder().decode(Message.self, from: body))?.message
    }
}

/// The account a token signs in as (GET /user).
public struct GitHubUser: Equatable, Sendable {
    public let id: Int
    public let login: String

    public init(id: Int, login: String) {
        self.id = id
        self.login = login
    }

    /// The address GitHub keeps private for commits, <id>+<login>@users.noreply.github.com:
    /// commits by it count on the account's contribution graph.
    public var noreplyEmail: String { "\(id)+\(login)@users.noreply.github.com" }
}

/// A repository GitHub made for you (POST /user/repos).
public struct CreatedRepository: Equatable, Sendable {
    public let repo: GitHubRepo
    public let isPrivate: Bool
}

/// GitHub's REST API (api.github.com, version 2022-11-28) through URLSession. It reads with
/// GET requests; the one request that writes is `createRepository`, POST /user/repos, sent
/// only when you click Create. It holds no sign-in; each call is given the token, if any.
///
/// It follows redirects itself, so the token goes to api.github.com and nowhere else: a log
/// download is redirected to blob storage, and that request goes out without it.
public final class GitHubClient: Sendable {
    public static let host = "api.github.com"
    static let apiVersion = "2022-11-28"
    static let redirectLimit = 5
    let session: URLSession

    public init(configuration: URLSessionConfiguration = GitHubClient.configuration()) {
        session = URLSession(configuration: configuration, delegate: RedirectRefusal(), delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// Ephemeral: no cookies, cache or stored credentials. A request gives up after 20 seconds
    /// without data, and after 90 in all, such as a long log.
    public static func configuration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 90
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.urlCredentialStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return c
    }

    /// A path of the API from its segments, each percent-encoded, so a branch such as
    /// feature/login stays one segment.
    public static func path(_ segments: String...) -> String {
        path(segments)
    }

    public static func path(_ segments: [String]) -> String {
        "/" + segments.map { $0.addingPercentEncoding(withAllowedCharacters: unreserved) ?? $0 }.joined(separator: "/")
    }

    /// RFC 3986's unreserved characters: ASCII letters and digits, - . _ ~
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// GET https://api.github.com plus `path` (percent-encoded already, see `path(_:)`).
    /// Statuses about the repository, such as 404, come back as they are; a used-up rate limit,
    /// a refused token, a server error or no network throw.
    public func get(_ path: String, query: [URLQueryItem] = [], token: GitHubToken?) async throws(GitHubError) -> GitHubResponse {
        var c = URLComponents()
        c.scheme = "https"
        c.host = GitHubClient.host
        c.percentEncodedPath = path
        if !query.isEmpty { c.queryItems = query }
        guard let url = c.url else { throw .unreadable("\(path) is not a path of GitHub's API") }
        let response = try await follow(url, token: token)
        try GitHubClient.refuse(response, signedIn: token != nil)
        if !(200..<300).contains(response.status) {
            Log.github.info("GET \(path, privacy: .public): \(response.status, privacy: .public)")
        }
        return response
    }

    /// Who the token signs in as: GET /user.
    public func user(token: GitHubToken) async throws(GitHubError) -> GitHubUser {
        struct User: Decodable {
            let id: Int
            let login: String
        }
        let response = try await get("/user", token: token)
        guard response.status == 200 else { throw .unreadable("GET /user answered \(response.status)") }
        let user = try response.decode(User.self)
        return GitHubUser(id: user.id, login: user.login)
    }

    /// Makes a new, empty repository on your account: POST /user/repos with auto_init false,
    /// so your first solution is its first commit. The one request that writes to GitHub.
    public func createRepository(name: String, isPrivate: Bool, token: GitHubToken) async throws(GitHubError) -> CreatedRepository {
        struct Body: Encodable {
            let name: String
            let `private`: Bool
            let autoInit: Bool
            let description: String
        }
        struct Created: Decodable {
            struct Owner: Decodable { let login: String }
            let name: String
            let owner: Owner
            let `private`: Bool
        }
        struct Problems: Decodable {
            struct Problem: Decodable { let message: String? }
            let message: String?
            let errors: [Problem]?
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let body: Data
        do {
            body = try encoder.encode(Body(name: name, private: isPrivate, autoInit: false, description: "Solutions to Go lessons, committed by Gopherwood"))
        } catch {
            throw .unreadable(error.localizedDescription)
        }
        guard let url = URL(string: "https://\(GitHubClient.host)/user/repos") else { throw .unreadable("/user/repos") }
        let response = try await send(url, method: "POST", body: body, token: token)
        try GitHubClient.refuse(response, signedIn: true)
        switch response.status {
        case 201:
            let created = try response.decode(Created.self)
            guard let repo = GitHubRepo(owner: created.owner.login, name: created.name) else {
                throw .unreadable("GitHub named the repository \(created.owner.login)/\(created.name)")
            }
            return CreatedRepository(repo: repo, isPrivate: created.private)
        default:
            let problems = try? JSONDecoder().decode(Problems.self, from: response.body)
            let detail = problems?.errors?.compactMap(\.message).first ?? problems?.message ?? "status \(response.status)"
            throw .refused("GitHub did not create \(name): \(detail).")
        }
    }

    /// Whether a request to `url` may carry the token: https to api.github.com itself.
    static func isAPI(_ url: URL) -> Bool {
        url.scheme == "https" && url.host() == host && (url.port == nil || url.port == 443) && url.user() == nil
    }

    /// Sends the request and follows redirects, giving the token only to api.github.com.
    private func follow(_ start: URL, token: GitHubToken?) async throws(GitHubError) -> GitHubResponse {
        var url = start
        for _ in 0...GitHubClient.redirectLimit {
            let response = try await send(url, token: GitHubClient.isAPI(url) ? token : nil)
            guard [301, 302, 303, 307, 308].contains(response.status), let location = response.header("location") else { return response }
            guard let next = URL(string: location, relativeTo: url)?.absoluteURL, next.scheme == "https" else {
                throw .unreadable("a redirect to an address that isn't https")
            }
            url = next
        }
        throw .tooManyRedirects
    }

    private func send(_ url: URL, method: String = "GET", body: Data? = nil, token: GitHubToken?) async throws(GitHubError) -> GitHubResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Gopherwood", forHTTPHeaderField: "User-Agent")
        if GitHubClient.isAPI(url) {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue(GitHubClient.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
            if let token { request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization") }
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw error.code == .cancelled ? .cancelled : .unreachable(error.localizedDescription)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw .unreadable("not an HTTP answer") }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        return GitHubResponse(status: http.statusCode, url: url, headers: headers, body: data)
    }

    /// The answers that are about the way to GitHub rather than about the repository.
    static func refuse(_ r: GitHubResponse, signedIn: Bool) throws(GitHubError) {
        switch r.status {
        case 401 where signedIn && isAPI(r.url):
            throw .badCredentials
        case 403, 429:
            if r.header("x-ratelimit-remaining") == "0" {
                throw .rateLimited(resetsAt: r.header("x-ratelimit-reset").flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) },
                                   signedIn: signedIn)
            }
            if let after = r.header("retry-after") { throw .slowDown(retryAfter: Int(after.trimmingCharacters(in: .whitespaces))) }
            if r.status == 429 || r.message?.localizedCaseInsensitiveContains("secondary rate limit") == true { throw .slowDown(retryAfter: nil) }
        case 500...599:
            throw .server(status: r.status)
        default:
            break
        }
    }
}

/// Keeps URLSession from following redirects, so GitHubClient follows them and decides which
/// request carries the token.
final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
