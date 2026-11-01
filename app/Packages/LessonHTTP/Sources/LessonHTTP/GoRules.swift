import Foundation
import NIOHTTP1

// The parts of Go's net/http client that decide what goes on the wire.

typealias Field = (name: String, value: String)

/// Where one request goes, taken from its URL.
struct Target: Sendable {
    let url: URL
    let usesTLS: Bool
    /// The host to connect to, without IPv6 brackets.
    let host: String
    let port: Int
    /// Host and port as written in the URL: the Host header, and what Go compares on redirects.
    let authority: String
    /// The host name in lowercase without brackets, for Go's subdomain rule on redirects.
    let hostname: String
    /// Path and query, as sent on the request line.
    let requestURI: String
    /// A user and password written in the URL.
    let credentials: (user: String, password: String)?

    init(_ url: URL) throws(LessonHTTPError) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw .invalidRequest("\(url.absoluteString) is not a valid URL")
        }
        switch parts.scheme?.lowercased() {
        case "http": usesTLS = false
        case "https": usesTLS = true
        default: throw .invalidRequest("unsupported protocol scheme \"\(parts.scheme ?? "")\" in \(url.absoluteString)")
        }
        guard let host = parts.encodedHost, !host.isEmpty else {
            throw .invalidRequest("no host in \(url.absoluteString)")
        }
        let port = parts.port ?? (usesTLS ? 443 : 80)
        guard (1...65535).contains(port) else {
            throw .invalidRequest("invalid port \(port) in \(url.absoluteString)")
        }
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        self.url = url
        self.host = bare
        self.port = port
        self.authority = parts.port.map { "\(host):\($0)" } ?? host
        self.hostname = bare.lowercased()
        let path = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
        self.requestURI = parts.percentEncodedQuery.map { "\(path)?\($0)" } ?? path
        if parts.user != nil || parts.password != nil {
            credentials = (parts.user ?? "", parts.password ?? "")
        } else {
            credentials = nil
        }
    }
}

/// RFC 9110 token characters, the only ones Go allows in a method or a header name.
func isToken(_ text: String) -> Bool {
    !text.isEmpty && text.utf8.allSatisfy { byte in
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"):
            true
        default:
            "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
    }
}

/// Checks the step's fields as Go's transport does (no control bytes but tab in a value) and
/// trims the values as Go writes them.
func validated(_ fields: [Field]) throws(LessonHTTPError) -> [Field] {
    try fields.map { (field: Field) throws(LessonHTTPError) -> Field in
        guard isToken(field.name) else {
            throw .invalidRequest("invalid header name \"\(field.name)\"")
        }
        guard field.value.utf8.allSatisfy({ $0 == 0x09 || ($0 >= 0x20 && $0 != 0x7F) }) else {
            throw .invalidRequest("invalid value for header \(field.name)")
        }
        return (name: field.name, value: field.value.trimmingCharacters(in: CharacterSet(charactersIn: " \t")))
    }
}

func sameName(_ a: String, _ b: String) -> Bool {
    a.lowercased() == b.lowercased()
}

/// The first value of a field, as Go's Header.Get returns it.
func firstValue(_ name: String, in fields: [Field]) -> String? {
    fields.first { sameName($0.name, name) }?.value
}

/// The Authorization value Go's SetBasicAuth writes.
func basicCredentials(user: String, password: String) -> String {
    "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
}

/// Fields Go writes from the request itself, never from Request.Header.
private let requestControlled: Set<String> = ["host", "user-agent", "content-length", "transfer-encoding", "trailer"]

/// The request head in the order Go's transport writes it: Host, User-Agent, Content-Length,
/// the request's own fields, then the Accept-Encoding and Connection the transport adds.
/// `askedForGzip` is true when the client added Accept-Encoding itself.
func requestHead(method: String, target: Target, fields: [Field], body: Data?) -> (head: HTTPRequestHead, askedForGzip: Bool) {
    var headers = HTTPHeaders()
    headers.add(name: "Host", value: target.authority)
    // A User-Agent set to an empty value means none, as in Go.
    let userAgent = firstValue("User-Agent", in: fields) ?? "Go-http-client/1.1"
    if !userAgent.isEmpty {
        headers.add(name: "User-Agent", value: userAgent)
    }
    if let length = contentLength(method: method, body: body) {
        headers.add(name: "Content-Length", value: String(length))
    }
    for field in fields where !requestControlled.contains(field.name.lowercased()) {
        headers.add(name: field.name, value: field.value)
    }
    // Go asks for gzip unless the request names an encoding or a range, and never for HEAD.
    let askedForGzip = method != "HEAD"
        && (firstValue("Accept-Encoding", in: fields) ?? "").isEmpty
        && (firstValue("Range", in: fields) ?? "").isEmpty
    if askedForGzip {
        headers.add(name: "Accept-Encoding", value: "gzip")
    }
    if !hasToken("close", in: firstValue("Connection", in: fields)) {
        headers.add(name: "Connection", value: "close")
    }
    let head = HTTPRequestHead(version: .http1_1, method: HTTPMethod(rawValue: method), uri: target.requestURI, headers: headers)
    return (head, askedForGzip)
}

/// Go sends a length for any body, and a length of 0 for POST, PUT and PATCH without one.
func contentLength(method: String, body: Data?) -> Int? {
    if let body, !body.isEmpty { return body.count }
    return ["POST", "PUT", "PATCH"].contains(method) ? 0 : nil
}

func hasToken(_ token: String, in value: String?) -> Bool {
    guard let value else { return false }
    return value.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == token }
}

/// Go's redirectBehavior: the statuses it follows, the method of the next request, and
/// whether the body goes along.
func redirectRule(status: Int, method: String) -> (method: String, keepsBody: Bool)? {
    switch status {
    case 301, 302, 303: (method == "GET" || method == "HEAD" ? method : "GET", false)
    case 307, 308: (method, true)
    default: nil
    }
}

/// Fields Go drops once a redirect leaves the first request's host and its subdomains.
let credentialFields: Set<String> = [
    "authorization", "www-authenticate", "cookie", "cookie2", "proxy-authorization", "proxy-authenticate",
]

/// Go's isDomainOrSubdomain.
func isDomainOrSubdomain(_ sub: String, of parent: String) -> Bool {
    if sub == parent { return true }
    if sub.contains(":") || sub.contains("%") { return false }
    return sub.hasSuffix("." + parent)
}

/// Go's refererForURL: the previous URL without credentials, and none from https to http.
func referer(from previous: URL, to next: URL) -> String? {
    if previous.scheme?.lowercased() == "https" && next.scheme?.lowercased() == "http" { return nil }
    guard var parts = URLComponents(url: previous, resolvingAgainstBaseURL: true) else { return nil }
    parts.user = nil
    parts.password = nil
    parts.fragment = nil
    return parts.string
}

/// Go decodes gzip only for a response that has a body by its rules: not 1xx, 204 or 304,
/// and not a Content-Length of 0.
func mayHaveBody(_ head: HTTPResponseHead) -> Bool {
    let status = Int(head.status.code)
    if status < 200 || status == 204 || status == 304 { return false }
    if hasToken("chunked", in: head.headers.first(name: "Transfer-Encoding")) { return true }
    if let length = head.headers.first(name: "Content-Length"),
       Int(length.trimmingCharacters(in: .whitespaces)) == 0 {
        return false
    }
    return true
}
