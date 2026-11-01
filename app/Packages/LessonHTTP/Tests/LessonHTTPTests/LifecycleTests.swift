import Foundation
import LessonHTTP
import Testing

@Suite("Timeouts, cancellation and failures")
struct LifecycleTests {
    @Test("the timeout ends a request the server never answers, and closes the connection")
    func timeout() async throws {
        try await withServer { server, client in
            let clock = ContinuousClock()
            let started = clock.now
            let error = await #expect(throws: LessonHTTPError.self) {
                try await client.send(LessonRequest(url: server.url("/silence"), timeout: .milliseconds(300)))
            }
            let elapsed = clock.now - started
            #expect(error == .timedOut)
            #expect(elapsed >= .milliseconds(300))
            #expect(elapsed < .seconds(3))
            #expect(await eventually { server.closedConnections == 1 })
        }
    }

    @Test("the timeout covers the body too")
    func timeoutDuringBody() async throws {
        try await withServer { server, client in
            let error = await #expect(throws: LessonHTTPError.self) {
                try await client.send(LessonRequest(url: server.url("/stall"), timeout: .milliseconds(300)))
            }
            #expect(error == .timedOut)
        }
    }

    @Test("cancelling the task ends the request and closes the connection at once")
    func cancellation() async throws {
        try await withServer { server, client in
            let request = LessonRequest(url: try server.url("/silence"), timeout: .seconds(30))
            let task = Task { try await client.send(request) }
            #expect(await eventually { server.requests.count == 1 })

            let clock = ContinuousClock()
            let cancelled = clock.now
            task.cancel()
            let result = await task.result
            #expect(clock.now - cancelled < .seconds(1))
            #expect(throws: LessonHTTPError.cancelled) { try result.get() }
            #expect(await eventually(within: .seconds(2)) { server.closedConnections == 1 })
        }
    }

    @Test("a task cancelled before sending never connects")
    func cancelledBeforeSending() async throws {
        try await withServer { server, client in
            let request = LessonRequest(url: try server.url("/"))
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await client.send(request)
            }
            await #expect(throws: LessonHTTPError.cancelled) { try await task.value }
            #expect(server.requests.isEmpty)
        }
    }

    @Test("a refused connection fails at once")
    func refused() async throws {
        let server = try await TestServer.start()
        let url = try server.url("/")
        try await server.stop()
        let client = LessonHTTPClient()
        let clock = ContinuousClock()
        let started = clock.now
        let error = await #expect(throws: LessonHTTPError.self) {
            try await client.send(LessonRequest(url: url, timeout: .seconds(10)))
        }
        #expect(error?.kind == .connectionFailed)
        #expect(clock.now - started < .seconds(2))
        await client.shutdown()
    }

    @Test("a host name that does not resolve fails without waiting for the timeout")
    func unknownHost() async throws {
        let client = LessonHTTPClient()
        let clock = ContinuousClock()
        let started = clock.now
        let error = await #expect(throws: LessonHTTPError.self) {
            try await client.send(LessonRequest(url: try #require(URL(string: "http://no-such-host.invalid/")), timeout: .seconds(10)))
        }
        #expect(error?.kind == .connectionFailed)
        #expect(clock.now - started < .seconds(5))
        await client.shutdown()
    }

    @Test("localhost reaches a server that listens on 127.0.0.1 only")
    func localhostName() async throws {
        try await withServer { server, client in
            let response = try await client.send(LessonRequest(url: try #require(URL(string: "http://localhost:\(server.port)/")), timeout: .seconds(5)))
            #expect(response.status == 200)
            #expect(server.requests.first?.value("Host") == "localhost:\(server.port)")
        }
    }

    @Test("https goes through TLS: a plain HTTP server fails the handshake")
    func tlsHandshake() async throws {
        try await withServer { server, client in
            let error = await #expect(throws: LessonHTTPError.self) {
                try await client.send(LessonRequest(url: server.url("/", scheme: "https"), timeout: .seconds(5)))
            }
            #expect(error?.kind == .tlsFailed)
        }
    }

    @Test(
        "a real HTTPS server; set LESSONHTTP_NETWORK_TESTS=1 to run it",
        .enabled(if: ProcessInfo.processInfo.environment["LESSONHTTP_NETWORK_TESTS"] == "1")
    )
    func realHTTPS() async throws {
        let client = LessonHTTPClient()
        let response = try await client.send(LessonRequest(url: try #require(URL(string: "https://example.com/")), timeout: .seconds(15)))
        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self).contains("Example Domain"))
        print("HTTPS GET https://example.com/: status \(response.status), \(response.body.count) bytes, \(response.duration)")
        await client.shutdown()
    }

    @Test("after shutdown every send fails, and shutting down twice is fine")
    func shutdown() async throws {
        let server = try await TestServer.start()
        let client = LessonHTTPClient()
        _ = try await client.send(LessonRequest(url: server.url("/")))
        await client.shutdown()
        await client.shutdown()
        let error = await #expect(throws: LessonHTTPError.self) {
            try await client.send(LessonRequest(url: server.url("/")))
        }
        #expect(error == .shutDown)
        try await server.stop()
    }

    @Test("a localhost GET")
    func localhostTiming() async throws {
        try await withServer { server, client in
            let url = try server.url("/")
            let first = try await client.send(LessonRequest(url: url))
            var durations: [Duration] = []
            for _ in 0..<50 {
                durations.append(try await client.send(LessonRequest(url: url)).duration)
            }
            durations.sort()
            let median = durations[durations.count / 2]
            print("localhost GET: first \(first.duration), then median \(median), fastest \(durations[0]), slowest \(durations[durations.count - 1])")
            #expect(median < .milliseconds(50))
        }
    }
}
