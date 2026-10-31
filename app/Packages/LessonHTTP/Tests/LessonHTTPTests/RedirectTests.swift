import Foundation
@testable import LessonHTTP
import Testing

@Suite("Redirects")
struct RedirectTests {
    @Test("redirects are followed, each hop with Go's Referer")
    func followed() async throws {
        try await withServer { server, client in
            let response = try await client.send(LessonRequest(url: server.url("/redirect/3")))
            #expect(response.status == 200)
            #expect(String(decoding: response.body, as: UTF8.self) == "done")
            #expect(try response.url == server.url("/redirect/0"))
            let sent = server.requests
            #expect(sent.map(\.uri) == ["/redirect/3", "/redirect/2", "/redirect/1", "/redirect/0"])
            #expect(sent.first?.value("Referer") == nil)
            let referers = sent.dropFirst().map { $0.value("Referer") }
            let previous: [String?] = try ["/redirect/3", "/redirect/2", "/redirect/1"].map { try server.url($0).absoluteString }
            #expect(referers == previous)
        }
    }

    @Test("with followRedirects off, the 3xx response itself comes back")
    func notFollowed() async throws {
        try await withServer { server, client in
            let request = LessonRequest(url: try server.url("/redirect/3"), followRedirects: false)
            let response = try await client.send(request)
            #expect(response.status == 302)
            #expect(value("Location", in: response.headers) == "/redirect/2")
            #expect(String(decoding: response.body, as: UTF8.self) == "redirecting")
            #expect(try response.url == server.url("/redirect/3"))
            #expect(server.requests.count == 1)
        }
    }

    @Test("Go's limit: nine redirects are followed, the tenth is an error")
    func limit() async throws {
        try await withServer { server, client in
            let nine = try await client.send(LessonRequest(url: server.url("/redirect/9")))
            #expect(nine.status == 200)
            #expect(server.requests.count == 10)

            let error = await #expect(throws: LessonHTTPError.self) {
                try await client.send(LessonRequest(url: server.url("/redirect/10")))
            }
            #expect(error == .tooManyRedirects)
            #expect(server.requests.count == 20)
        }
    }

    @Test("301, 302 and 303 turn a POST into a GET with no body", arguments: [301, 302, 303])
    func switchToGet(status: Int) async throws {
        try await withServer { server, client in
            let json = Data(#"{"title":"redirect me"}"#.utf8)
            let request = LessonRequest(
                method: "POST", url: try server.url("/status/\(status)?location=/echo"),
                headers: [("Content-Type", "application/json"), ("X-Lesson", "redirects")], body: json
            )
            let response = try await client.send(request)
            #expect(response.status == 200)
            #expect(response.body.isEmpty)
            let sent = server.requests
            try #require(sent.count == 2)
            #expect(sent[0].method == "POST")
            #expect(sent[0].body == json)
            #expect(sent[1].method == "GET")
            #expect(sent[1].uri == "/echo")
            #expect(sent[1].body.isEmpty)
            #expect(sent[1].value("Content-Length") == nil)
            // Go copies the first request's fields to every hop.
            #expect(sent[1].value("Content-Type") == "application/json")
            #expect(sent[1].value("X-Lesson") == "redirects")
        }
    }

    @Test("307 and 308 keep the method and the body", arguments: [307, 308])
    func keepBody(status: Int) async throws {
        try await withServer { server, client in
            let json = Data(#"{"title":"keep me","n":1}"#.utf8)
            let request = LessonRequest(
                method: "POST", url: try server.url("/status/\(status)?location=/echo"),
                headers: [("Content-Type", "application/json")], body: json
            )
            let response = try await client.send(request)
            #expect(response.status == 200)
            #expect(response.body == json)
            let sent = server.requests
            try #require(sent.count == 2)
            #expect(sent[1].method == "POST")
            #expect(sent[1].body == json)
            #expect(sent[1].value("Content-Length") == String(json.count))
        }
    }

    @Test("HEAD stays HEAD across a 302, as in Go")
    func headStaysHead() async throws {
        try await withServer { server, client in
            let response = try await client.send(LessonRequest(method: "HEAD", url: server.url("/status/302?location=/head")))
            #expect(response.status == 200)
            #expect(response.body.isEmpty)
            #expect(server.requests.map(\.method) == ["HEAD", "HEAD"])
        }
    }

    @Test("Authorization and cookies are dropped when a redirect goes to another host")
    func otherHost() async throws {
        let first = try await TestServer.start(host: "127.0.0.1")
        let second = try await TestServer.start(host: "::1")
        let client = LessonHTTPClient()
        let target = try second.url("/echo").absoluteString
        let location = try #require(target.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let request = LessonRequest(
            url: try first.url("/status/302?location=\(location)"),
            headers: [("Cookie", "session=1"), ("X-Lesson", "redirects")],
            basicAuth: (user: "gopher", password: "secret")
        )
        let response = try await client.send(request)
        #expect(response.status == 200)
        #expect(response.url.absoluteString == target)

        let before = try #require(first.requests.first)
        #expect(before.value("Authorization") != nil)
        #expect(before.value("Cookie") == "session=1")
        let after = try #require(second.requests.first)
        #expect(after.value("Authorization") == nil)
        #expect(after.value("Cookie") == nil)
        #expect(after.value("X-Lesson") == "redirects")
        #expect(after.value("Host") == second.authority)
        #expect(after.value("Referer") == request.url.absoluteString)

        await client.shutdown()
        try await first.stop()
        try await second.stop()
    }

    @Test("Authorization stays on a redirect to the same host")
    func sameHost() async throws {
        try await withServer { server, client in
            let request = LessonRequest(
                url: try server.url("/status/302?location=/echo"),
                headers: [("Cookie", "session=1")],
                basicAuth: (user: "gopher", password: "secret")
            )
            _ = try await client.send(request)
            let sent = server.requests
            try #require(sent.count == 2)
            #expect(sent[1].value("Authorization") == sent[0].value("Authorization"))
            #expect(sent[1].value("Cookie") == "session=1")
        }
    }

    @Test("a 3xx without a Location comes back as it is")
    func noLocation() async throws {
        try await withServer { server, client in
            let response = try await client.send(LessonRequest(url: server.url("/status/302")))
            #expect(response.status == 302)
            #expect(server.requests.count == 1)
        }
    }

    @Test("a redirect to another scheme is an error")
    func otherScheme() async throws {
        try await withServer { server, client in
            let error = await #expect(throws: LessonHTTPError.self) {
                try await client.send(LessonRequest(url: server.url("/status/302?location=ftp%3A%2F%2Fexample.com%2F")))
            }
            #expect(error?.kind == .invalidRedirect)
        }
    }

    @Test("credentials go to the same host and its subdomains only, as Go decides")
    func subdomains() {
        #expect(isDomainOrSubdomain("example.com", of: "example.com"))
        #expect(isDomainOrSubdomain("api.example.com", of: "example.com"))
        #expect(!isDomainOrSubdomain("example.com", of: "api.example.com"))
        #expect(!isDomainOrSubdomain("badexample.com", of: "example.com"))
        #expect(!isDomainOrSubdomain("example.com.evil.test", of: "example.com"))
        #expect(!isDomainOrSubdomain("::1", of: "1"))
    }
}
