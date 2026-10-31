import Foundation
import LessonHTTP
import Testing

@Suite("Responses")
struct ResponseTests {
    @Test("a chunked body and its trailers, as GET /httpbin/range/4096 returns them")
    func chunkedTrailers() async throws {
        try await withServer { server, client in
            let response = try await client.send(LessonRequest(url: server.url("/httpbin/range/4096")))
            let expected = rangeBytes(4096)
            #expect(response.status == 200)
            #expect(response.body.count == 4096)
            #expect(response.body == Data(expected))
            #expect(response.trailers.map { $0.name } == ["X-Content-Sha256", "X-Content-Length"])
            #expect(value("X-Content-Sha256", in: response.trailers) == sha256Hex(expected))
            #expect(value("X-Content-Length", in: response.trailers) == "4096")
            #expect(value("Trailer", in: response.headers) == "X-Content-Sha256, X-Content-Length")
            #expect(value("Transfer-Encoding", in: response.headers) == "chunked")
            #expect(try response.url == server.url("/httpbin/range/4096"))
        }
    }

    @Test("a HEAD response has no body, whatever its Content-Length says")
    func head() async throws {
        try await withServer { server, client in
            let response = try await client.send(LessonRequest(method: "HEAD", url: server.url("/head")))
            #expect(response.status == 200)
            #expect(response.body.isEmpty)
            #expect(value("Content-Length", in: response.headers) == "1234")
            let sent = try #require(server.requests.first)
            #expect(sent.method == "HEAD")
            // Go never asks for gzip on HEAD.
            #expect(sent.value("Accept-Encoding") == nil)
        }
    }

    @Test("gzip is decoded when the client asked for it, as Go does", arguments: ["/gzip", "/gzip?chunked"])
    func transparentGzip(path: String) async throws {
        try await withServer { server, client in
            let response = try await client.send(LessonRequest(url: server.url(path)))
            #expect(server.requests.first?.value("Accept-Encoding") == "gzip")
            #expect(response.status == 200)
            #expect(response.body == Data(gzipText.utf8))
            #expect(value("Content-Encoding", in: response.headers) == nil)
            #expect(value("Content-Length", in: response.headers) == nil)
            #expect(value("Content-Type", in: response.headers) == "text/plain")
        }
    }

    @Test("gzip the step asked for itself is left as it came")
    func requestedGzip() async throws {
        try await withServer { server, client in
            let request = LessonRequest(url: try server.url("/gzip"), headers: [("Accept-Encoding", "gzip")])
            let response = try await client.send(request)
            let compressed = gzipped(Data(gzipText.utf8))
            #expect(response.body == compressed)
            #expect(value("Content-Encoding", in: response.headers) == "gzip")
            #expect(value("Content-Length", in: response.headers) == String(compressed.count))
        }
    }

    @Test("a body that ends when the server closes")
    func bodyUntilClose() async throws {
        try await withRawServer(answer: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nread until close") { server, client in
            let response = try await client.send(LessonRequest(url: server.url()))
            #expect(response.status == 200)
            #expect(String(decoding: response.body, as: UTF8.self) == "read until close")
        }
    }

    @Test("trailers and chunk extensions written by hand")
    func handWrittenChunks() async throws {
        let answer = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTrailer: x-checksum\r\n\r\n"
            + "5;name=value\r\nhello\r\n6\r\n world\r\n0\r\nx-checksum: abc\r\nX-Second: 2\r\n\r\n"
        try await withRawServer(answer: answer) { server, client in
            let response = try await client.send(LessonRequest(url: server.url()))
            #expect(String(decoding: response.body, as: UTF8.self) == "hello world")
            #expect(response.trailers.map { "\($0.name): \($0.value)" } == ["x-checksum: abc", "X-Second: 2"])
        }
    }

    @Test("informational responses are skipped, as in Go")
    func informational() async throws {
        let answer = "HTTP/1.1 103 Early Hints\r\nLink: </app.css>\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
        try await withRawServer(answer: answer) { server, client in
            let response = try await client.send(LessonRequest(url: server.url()))
            #expect(response.status == 200)
            #expect(String(decoding: response.body, as: UTF8.self) == "ok")
        }
    }

    @Test("a body cut short is an error")
    func truncatedBody() async throws {
        try await withRawServer(answer: "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nonly a little") { server, client in
            let error = await #expect(throws: LessonHTTPError.self) {
                try await client.send(LessonRequest(url: server.url()))
            }
            #expect(error?.kind == .connectionLost)
        }
    }

    @Test("a response that is not HTTP is an error")
    func notHTTP() async throws {
        try await withRawServer(answer: "SSH-2.0-OpenSSH_9.9\r\n\r\n") { server, client in
            let error = await #expect(throws: LessonHTTPError.self) {
                try await client.send(LessonRequest(url: server.url()))
            }
            #expect(error?.kind == .invalidResponse)
        }
    }

    @Test("a gzip body that does not decode is an error")
    func badGzip() async throws {
        try await withRawServer(answer: "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 5\r\n\r\nhello") { server, client in
            let error = await #expect(throws: LessonHTTPError.self) {
                try await client.send(LessonRequest(url: server.url()))
            }
            #expect(error?.kind == .invalidResponse)
        }
    }

    @Test("an empty gzip response keeps its headers, as in Go")
    func emptyGzip() async throws {
        try await withRawServer(answer: "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 0\r\n\r\n") { server, client in
            let response = try await client.send(LessonRequest(url: server.url()))
            #expect(response.body.isEmpty)
            #expect(value("Content-Encoding", in: response.headers) == "gzip")
            #expect(value("Content-Length", in: response.headers) == "0")
        }
    }
}
