import Foundation
import LessonHTTP
import Testing

@Suite("Requests")
struct RequestTests {
    @Test("exactly Go's default headers, then the step's in order")
    func exactHeaders() async throws {
        try await withServer { server, client in
            let request = LessonRequest(
                url: try server.url("/headers?lesson=1&q=a%20b"),
                headers: [("X-Lesson", "trailers"), ("Accept", "application/json")]
            )
            _ = try await client.send(request)
            let sent = try #require(server.requests.first)
            #expect(sent.method == "GET")
            #expect(sent.uri == "/headers?lesson=1&q=a%20b")
            #expect(sent.lines == [
                "Host: \(server.authority)",
                "User-Agent: Go-http-client/1.1",
                "X-Lesson: trailers",
                "Accept: application/json",
                "Accept-Encoding: gzip",
                "Connection: close",
            ])
            #expect(sent.body.isEmpty)
        }
    }

    @Test("a body gets a Content-Length after Host and User-Agent")
    func headersWithBody() async throws {
        try await withServer { server, client in
            let json = Data(#"{"name":"gopher"}"#.utf8)
            let request = LessonRequest(
                method: "POST", url: try server.url("/echo"),
                headers: [("Content-Type", "application/json")], body: json
            )
            _ = try await client.send(request)
            let sent = try #require(server.requests.first)
            #expect(sent.lines == [
                "Host: \(server.authority)",
                "User-Agent: Go-http-client/1.1",
                "Content-Length: \(json.count)",
                "Content-Type: application/json",
                "Accept-Encoding: gzip",
                "Connection: close",
            ])
        }
    }

    @Test("POST, PUT and PATCH without a body send Content-Length 0; other methods send none")
    func emptyBodies() async throws {
        try await withServer { server, client in
            for method in ["POST", "PUT", "PATCH", "DELETE", "OPTIONS", "GET"] {
                _ = try await client.send(LessonRequest(method: method, url: server.url("/echo")))
            }
            let lengths = server.requests.map { "\($0.method) \($0.value("Content-Length") ?? "none")" }
            #expect(lengths == ["POST 0", "PUT 0", "PATCH 0", "DELETE none", "OPTIONS none", "GET none"])
            #expect(server.requests.allSatisfy { $0.value("Transfer-Encoding") == nil })
        }
    }

    @Test("the step's User-Agent, Accept-Encoding and Connection replace the defaults; Host and framing fields are ignored")
    func stepOverrides() async throws {
        try await withServer { server, client in
            let request = LessonRequest(
                url: try server.url("/"),
                headers: [
                    ("Host", "elsewhere.example"), ("Content-Length", "99"), ("Transfer-Encoding", "chunked"),
                    ("Trailer", "X-Sum"), ("User-Agent", "lesson-checker/1.0"), ("Accept-Encoding", "identity"),
                    ("Connection", "close"),
                ]
            )
            _ = try await client.send(request)
            let sent = try #require(server.requests.first)
            #expect(sent.lines == [
                "Host: \(server.authority)",
                "User-Agent: lesson-checker/1.0",
                "Accept-Encoding: identity",
                "Connection: close",
            ])
        }
    }

    @Test("an empty User-Agent sends none, and a Range turns off gzip, as in Go")
    func goQuirks() async throws {
        try await withServer { server, client in
            _ = try await client.send(LessonRequest(url: server.url("/"), headers: [("User-Agent", ""), ("Range", "bytes=0-1")]))
            let sent = try #require(server.requests.first)
            #expect(sent.lines == ["Host: \(server.authority)", "Range: bytes=0-1", "Connection: close"])
        }
    }

    @Test("basic auth goes in an Authorization header and replaces the step's")
    func basicAuth() async throws {
        try await withServer { server, client in
            let request = LessonRequest(
                url: try server.url("/echo"),
                headers: [("Authorization", "Bearer old-token"), ("X-Lesson", "auth")],
                basicAuth: (user: "gopher", password: "pa:ss wörd")
            )
            _ = try await client.send(request)
            let sent = try #require(server.requests.first)
            #expect(sent.count("Authorization") == 1)
            #expect(sent.value("Authorization") == "Basic Z29waGVyOnBhOnNzIHfDtnJk")
            #expect(sent.value("X-Lesson") == "auth")
        }
    }

    @Test("a user and password in the URL become basic auth")
    func urlCredentials() async throws {
        try await withServer { server, client in
            _ = try await client.send(LessonRequest(url: try #require(URL(string: "http://user:p%40ss@\(server.authority)/echo"))))
            let sent = try #require(server.requests.first)
            #expect(sent.value("Authorization") == "Basic dXNlcjpwQHNz")
            #expect(sent.value("Host") == server.authority)
        }
    }

    @Test("a form body is sent byte for byte")
    func formBody() async throws {
        try await withServer { server, client in
            let form = Data("name=Gopher+Go&lang=go%21&empty=&city=Bak%C4%B1&note=a%26b%3Dc".utf8)
            let request = LessonRequest(
                method: "POST", url: try server.url("/echo"),
                headers: [("Content-Type", "application/x-www-form-urlencoded")], body: form
            )
            let response = try await client.send(request)
            let sent = try #require(server.requests.first)
            #expect(sent.body == form)
            #expect(sent.value("Content-Length") == String(form.count))
            #expect(sent.value("Content-Type") == "application/x-www-form-urlencoded")
            #expect(response.body == form)
        }
    }

    @Test("a JSON body is sent byte for byte")
    func jsonBody() async throws {
        try await withServer { server, client in
            let text = #"{"name":"gopher","note":"café ☕ ünï \n","tags":["go","http"],"stars":5,"nested":{"ok":true}}"# + "\n"
            let json = Data(text.utf8)
            #expect(json.count > text.count)
            let request = LessonRequest(
                method: "PUT", url: try server.url("/echo"),
                headers: [("Content-Type", "application/json")], body: json
            )
            let response = try await client.send(request)
            let sent = try #require(server.requests.first)
            #expect(sent.body == json)
            #expect(sent.value("Content-Length") == String(json.count))
            #expect(response.body == json)
        }
    }

    @Test("a large binary body arrives intact")
    func largeBody() async throws {
        try await withServer { server, client in
            var generator = SplitMix(seed: 42)
            let bytes = Data((0..<(1 << 20)).map { _ in UInt8(truncatingIfNeeded: generator.next()) })
            let response = try await client.send(LessonRequest(method: "POST", url: server.url("/echo"), body: bytes))
            #expect(server.requests.first?.body == bytes)
            #expect(response.body == bytes)
        }
    }

    @Test("bad methods, header names, header values and schemes are refused before connecting")
    func invalidRequests() async throws {
        try await withServer { server, client in
            let url = try server.url("/")
            let requests = [
                LessonRequest(method: "BAD METHOD", url: url),
                LessonRequest(url: url, headers: [("X Bad", "1")]),
                LessonRequest(url: url, headers: [("X-Injected", "a\r\nX-Evil: 1")]),
                LessonRequest(url: try #require(URL(string: "ftp://\(server.authority)/"))),
                LessonRequest(url: try #require(URL(string: "http:///no-host"))),
            ]
            for request in requests {
                let error = await #expect(throws: LessonHTTPError.self) { try await client.send(request) }
                #expect(error?.kind == .invalidRequest)
            }
            #expect(server.requests.isEmpty)
        }
    }

    @Test("header values are trimmed as Go writes them")
    func trimmedValues() async throws {
        try await withServer { server, client in
            _ = try await client.send(LessonRequest(url: server.url("/"), headers: [("X-Padded", " \tvalue  ")]))
            #expect(server.requests.first?.value("X-Padded") == "value")
        }
    }
}

/// A small deterministic generator for test data.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
