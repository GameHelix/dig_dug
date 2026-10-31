/// Realistic inputs for the lessons' jq queries: the logs that the courses' servers write, the
/// reports their check programs print, and the HTTP responses their steps receive.
enum Fixture {
    // MARK: Logs, read as JSON lines

    /// Linko's linko.access.log once it logs requests with ids, redacts users and URLs, adds
    /// build info, and logs errors with stack traces.
    static let linkoAccessLog = #"""
        {"time":"2026-10-31T10:02:11.481203Z","level":"INFO","msg":"Linko is running","env":"development","hostname":"linko-dev","git_sha":"4f1c2ab9","build_time":"2026-10-31T09:58:40Z","port":8899}
        {"time":"2026-10-31T10:02:14.120845Z","level":"INFO","msg":"Served request","env":"development","hostname":"linko-dev","git_sha":"4f1c2ab9","build_time":"2026-10-31T09:58:40Z","request_id":"bootdev-test-id","method":"GET","path":"/","client_ip":"127.0.0.x","duration":184250,"request_body_bytes":0,"response_status":200,"response_body_bytes":1342}
        {"time":"2026-10-31T10:02:15.004311Z","level":"INFO","msg":"Successfully generated short code","env":"development","hostname":"linko-dev","git_sha":"4f1c2ab9","build_time":"2026-10-31T09:58:40Z","request_id":"8d4e2f6a-31c7-4b9e-a0f5-6c2d8e1b7a93","short_code":"x7Kp2Q","long_url":"https://example.com/account/reset?token=REDACTED"}
        {"time":"2026-10-31T10:02:15.004902Z","level":"INFO","msg":"Served request","env":"development","hostname":"linko-dev","git_sha":"4f1c2ab9","build_time":"2026-10-31T09:58:40Z","request_id":"8d4e2f6a-31c7-4b9e-a0f5-6c2d8e1b7a93","method":"POST","path":"/api/shorten","client_ip":"127.0.0.x","duration":2201873,"request_body_bytes":58,"response_status":201,"response_body_bytes":27}
        {"time":"2026-10-31T10:02:16.338127Z","level":"INFO","msg":"Served request","env":"development","hostname":"linko-dev","git_sha":"4f1c2ab9","build_time":"2026-10-31T09:58:40Z","request_id":"2b9f7c1d-0e4a-4d6b-8f3e-9a5c1d7e2b40","method":"POST","path":"/api/shorten","client_ip":"127.0.0.x","duration":96112,"request_body_bytes":41,"response_status":400,"response_body_bytes":64,"error":{"message":"invalid URL: parse \"ht!tp://example.com\": first path segment in URL cannot contain colon"}}
        {"time":"2026-10-31T10:02:17.902566Z","level":"INFO","msg":"Served request","env":"development","hostname":"linko-dev","git_sha":"4f1c2ab9","build_time":"2026-10-31T09:58:40Z","request_id":"6e1a3c5b-7d9f-4b2e-a8c0-3f5d7b9e1a24","method":"POST","path":"/api/login","client_ip":"127.0.0.x","duration":58331047,"request_body_bytes":52,"response_status":200,"response_body_bytes":64,"user":"[REDACTED]"}
        {"time":"2026-10-31T10:02:19.415008Z","level":"ERROR","msg":"error validating password","env":"development","hostname":"linko-dev","git_sha":"4f1c2ab9","build_time":"2026-10-31T09:58:40Z","request_id":"c3d5e7f9-1a2b-4c6d-9e8f-0a1b2c3d4e5f","user":"saruman","error":{"message":"crypto/bcrypt: hashedPassword is not the hash of the given password","stack_trace":["main.(*server).validatePassword\n\t/home/gopher/linko/auth.go:41","main.(*server).handleLogin\n\t/home/gopher/linko/auth.go:87","net/http.HandlerFunc.ServeHTTP\n\t/usr/local/go/src/net/http/server.go:2322"]}}
        {"time":"2026-10-31T10:02:19.415440Z","level":"INFO","msg":"Served request","env":"development","hostname":"linko-dev","git_sha":"4f1c2ab9","build_time":"2026-10-31T09:58:40Z","request_id":"c3d5e7f9-1a2b-4c6d-9e8f-0a1b2c3d4e5f","method":"POST","path":"/api/login","client_ip":"127.0.0.x","duration":61204338,"request_body_bytes":55,"response_status":401,"response_body_bytes":13,"error":{"message":"unauthorized"}}
        {"time":"2026-10-31T10:02:21.770093Z","level":"INFO","msg":"Served request","env":"development","hostname":"linko-dev","git_sha":"4f1c2ab9","build_time":"2026-10-31T09:58:40Z","request_id":"f0e1d2c3-b4a5-4697-8879-6a5b4c3d2e1f","method":"POST","path":"/api/login","client_ip":"127.0.0.x","duration":5002113,"request_body_bytes":52,"response_status":500,"response_body_bytes":22,"error":{"message":"database is locked","stack_trace":["main.(*store).findUser\n\t/home/gopher/linko/store.go:58","main.(*server).handleLogin\n\t/home/gopher/linko/auth.go:79"]}}
        {"time":"2026-10-31T10:02:23.118440Z","level":"INFO","msg":"Served request","env":"development","hostname":"linko-dev","git_sha":"4f1c2ab9","build_time":"2026-10-31T09:58:40Z","request_id":"0a9b8c7d-6e5f-4a3b-2c1d-0e9f8a7b6c5d","method":"GET","path":"/not-real","client_ip":"127.0.0.x","duration":40875,"request_body_bytes":0,"response_status":404,"response_body_bytes":19,"error":{"message":"not found"}}

        """#

    /// linko.access.log in the lesson that logs errors as text with the stack.
    static let linkoStackTextLog = #"""
        {"time":"2026-10-31T09:41:02.551102Z","level":"ERROR","msg":"error validating password","user":"saruman","error":"invalid password:\n    main.(*server).validatePassword\n        /home/gopher/linko/auth.go:41\n    main.(*server).handleLogin\n        /home/gopher/linko/auth.go:87"}
        {"time":"2026-10-31T09:41:02.551730Z","level":"INFO","msg":"Served request","method":"POST","path":"/api/login","response_status":401}
        """#

    /// linko.access.log after looking up a short code with no file behind it.
    static let linkoLookupLog = #"""
        {"time":"2026-10-31T09:20:44.913385Z","level":"ERROR","msg":"failed to lookup URL","short_code":"WTF","error":"open data/WTF: no such file or directory"}
        {"time":"2026-10-31T09:20:44.913790Z","level":"INFO","msg":"Served request","method":"GET","path":"/WTF","response_status":404}
        """#

    /// linko.access.log after listing URLs with one bad entry in data/.
    static let linkoListLog = #"""
        {"time":"2026-10-31T09:31:07.210448Z","level":"ERROR","msg":"failed to list URLs","error":{"message":"read data/BADENTRY: is a directory","path":"data/BADENTRY"}}
        {"time":"2026-10-31T09:31:07.210913Z","level":"INFO","msg":"Served request","method":"GET","path":"/api/urls","response_status":500}
        """#

    /// linko.access.log after listing URLs with two bad entries, logged as joined errors.
    static let linkoJoinedErrorsLog = #"""
        {"time":"2026-10-31T09:36:52.004112Z","level":"ERROR","msg":"failed to list URLs","errors":{"error_1":{"message":"read data/BADENTRY1: is a directory","path":"data/BADENTRY1"},"error_2":{"message":"read data/BADENTRY2: is a directory","path":"data/BADENTRY2"}}}
        {"time":"2026-10-31T09:36:52.004650Z","level":"INFO","msg":"Served request","method":"GET","path":"/api/urls","response_status":500}
        """#

    /// Bearly Secure's data/bearly-secure.log, with personal data redacted where it must be.
    static let bearlySecureLog = #"""
        {"time":"2026-10-31T11:02:13.481Z","level":"INFO","event":"login_attempt","email":"[REDACTED]","userId":null,"success":false,"reason":"invalid_credentials"}
        {"time":"2026-10-31T11:02:19.006Z","level":"INFO","event":"login_attempt","email":"[REDACTED]","userId":42,"success":true}
        {"time":"2026-10-31T11:03:40.770Z","level":"INFO","event":"checkout_started","email":"[REDACTED]","userId":42,"orderId":1007,"totalCents":4498,"shippingName":"[REDACTED]","shippingAddress":"[REDACTED]","shippingCity":"[REDACTED]","shippingRegion":"[REDACTED]","shippingPostalCode":"[REDACTED]"}
        {"time":"2026-10-31T11:05:02.118Z","level":"INFO","event":"password_reset_request","email":"grenda@example.com","success":true,"resetLink":"http://localhost:8080/password-reset/3f7a9c2e1b4d6f8a0c5e7b9d2f4a6c8e1b3d5f7a9c2e4b6d8f0a1c3e5b7d9f2a"}
        {"time":"2026-10-31T11:06:31.902Z","level":"INFO","event":"account_accessed","userId":7,"email":"grenda@example.com","expiresAt":"2026-11-30T11:06:31Z"}
        """#

    // MARK: Command output, read as one JSON value

    /// `go env -json GOVERSION`, as Go prints it.
    static func goEnv(_ version: String) -> String {
        "{\n\t\"GOVERSION\": \"\(version)\"\n}\n"
    }

    /// The report of `go run ./lessonchecks/revokeactivesessions`.
    static let revokedSessionsReport = #"{"revoked":3,"oldSessionActive":false,"boundarySessionActive":false,"newSessionActive":false,"revocationTimestampMatchesDatabaseClock":true,"alreadyRevokedSessionUnchanged":true,"repeatRevocationNoChanges":true}"#

    /// The report of `go run ./lessonchecks/passwordreset inspect <token>`.
    static let resetTokenReport = #"{"hashMatches":true,"rawTokenStored":false,"expiresAboutFifteenMinutes":true,"expiresInSeconds":899}"#

    /// The report of `go run ./lessonchecks/authratelimits`: the statuses of each burst.
    static let authRateLimitsReport: String = {
        func statuses(_ status: Int, _ count: Int, then last: Int) -> String {
            "[" + (Array(repeating: String(status), count: count) + [String(last)]).joined(separator: ",") + "]"
        }
        return """
            {"knownLoginStatuses":\(statuses(401, 5, then: 429)),"unknownLoginStatuses":\(statuses(401, 5, then: 429)),\
            "loginIpStatuses":\(statuses(401, 20, then: 429)),"totpIpStatuses":\(statuses(302, 20, then: 429)),\
            "knownResetStatuses":\(statuses(200, 3, then: 429)),"unknownResetStatuses":\(statuses(200, 3, then: 429)),\
            "resetIpStatuses":\(statuses(200, 10, then: 429)),"loginLimitBodiesMatch":true,"resetLimitBodiesMatch":true,\
            "resetNeutralBodiesMatch":true,"blockedAttemptsHaveRetryAfter":true}
            """
    }()

    // MARK: HTTP responses: Chirpy

    static let waltID = "0c6c6b4e-5f1a-4f4e-9a37-6b8f8f2d3c11"
    static let saulID = "7d2e9f41-0b3c-4a8e-b6d5-1f9e2c4a8b70"
    static let chirpID = "e5b1c0d7-3a2f-4f6e-8d9c-7b4a1e0f2c56"

    static let createdUser = #"{"id":"\#(waltID)","created_at":"2026-10-31T10:15:02.123456Z","updated_at":"2026-10-31T10:15:02.123456Z","email":"walt@breakingbad.com","is_chirpy_red":false}"#

    static let updatedUser = #"{"id":"\#(waltID)","created_at":"2026-10-31T10:15:02.123456Z","updated_at":"2026-10-31T10:19:47.554012Z","email":"walter@breakingbad.com","is_chirpy_red":false}"#

    static let login = #"{"id":"\#(saulID)","created_at":"2026-10-31T10:16:40.902117Z","updated_at":"2026-10-31T10:16:40.902117Z","email":"saul@bettercall.com","is_chirpy_red":true,"token":"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJjaGlycHktYWNjZXNzIiwic3ViIjoiN2QyZTlmNDEiLCJleHAiOjE3NjE5MTE0MDB9.mQ3cYk2uBq0n8p1xZr7tV5wJ4sD6fH9gL3aE0iO2uT8","refresh_token":"9c4e1f7a2b8d3e6f0a5c9b2d7e1f4a8c3b6d0e9f2a5c8b1d4e7f0a3c6b9d2e5f"}"#

    static let chirp = #"{"id":"\#(chirpID)","created_at":"2026-10-31T10:17:12.330981Z","updated_at":"2026-10-31T10:17:12.330981Z","body":"I'm gonna be a damn good developer, and people are gonna know about it.","user_id":"\#(saulID)"}"#

    static func chirps(_ bodies: [String]) -> String {
        "[" + bodies.enumerated().map { index, body in
            #"{"id":"00000000-0000-4000-8000-00000000000\#(index)","created_at":"2026-10-31T10:2\#(index):00.000000Z","updated_at":"2026-10-31T10:2\#(index):00.000000Z","body":"\#(body)","user_id":"\#(waltID)"}"#
        }.joined(separator: ",") + "]"
    }

    static let chirpsAscending = chirps(["I'm the one who knocks!", "Gale!", "Cmon Pinkman", "Darn that fly, I just wanna cook"])
    static let chirpsDescending = chirps(["Darn that fly, I just wanna cook", "Cmon Pinkman", "Gale!", "I'm the one who knocks!"])

    // MARK: HTTP responses: Peril's RabbitMQ management API

    static func queue(_ name: String, durable: Bool, autoDelete: Bool, exclusive: Bool, ready: Int, stats: String) -> String {
        #"{"name":"\#(name)","vhost":"/","type":"classic","durable":\#(durable),"auto_delete":\#(autoDelete),"exclusive":\#(exclusive),"arguments":{"x-dead-letter-exchange":"peril_dlx"},"state":"running","consumers":1,"messages":\#(ready),"messages_ready":\#(ready),"messages_unacknowledged":0,"message_stats":\#(stats),"node":"rabbit@peril"}"#
    }

    static let gameLogsQueue = queue("game_logs", durable: true, autoDelete: false, exclusive: false, ready: 503, stats: #"{"publish":503,"publish_details":{"rate":12.4},"deliver_get":0,"redeliver":0}"#)
    static let drainedGameLogsQueue = queue("game_logs", durable: true, autoDelete: false, exclusive: false, ready: 0, stats: #"{"publish":503,"deliver_get":503,"ack":503,"redeliver":0}"#)
    static let sunTzuPauseQueue = queue("pause.suntzu", durable: false, autoDelete: true, exclusive: true, ready: 0, stats: #"{"publish":2,"deliver_get":2,"redeliver":0}"#)
    static let washingtonPauseQueue = queue("pause.washington", durable: false, autoDelete: true, exclusive: true, ready: 0, stats: #"{"publish":3,"deliver_get":3,"ack":3,"redeliver":0}"#)
    static let pauseTestQueue = queue("pause_test", durable: true, autoDelete: false, exclusive: false, ready: 4, stats: #"{"publish":4,"redeliver":0}"#)
    static let deadLetterQueue = queue("peril_dlq", durable: true, autoDelete: false, exclusive: false, ready: 7, stats: #"{"publish":7,"redeliver":0}"#)
    static let warQueue = queue("war", durable: true, autoDelete: false, exclusive: false, ready: 0, stats: #"{"publish":64,"deliver_get":201,"ack":56,"nack":145,"redeliver":137}"#)

    static let readyColumn = #"{"messages_ready":503}"#

    static let overview = #"{"management_version":"4.2.0","rates_mode":"basic","product_version":"4.2.0","product_name":"RabbitMQ","rabbitmq_version":"4.2.0","cluster_name":"rabbit@peril","erlang_version":"27.3.4","message_stats":{"publish":1342,"publish_details":{"rate":3.2},"drop_unroutable":3,"drop_unroutable_details":{"rate":0.0},"deliver_get":1290},"object_totals":{"connections":3,"channels":5,"exchanges":9,"queues":6,"consumers":4}}"#

    static let directExchange = #"{"name":"peril_direct","vhost":"/","type":"direct","durable":true,"auto_delete":false,"internal":false,"arguments":{}}"#
    static let topicExchange = #"{"name":"peril_topic","vhost":"/","type":"topic","durable":true,"auto_delete":false,"internal":false,"arguments":{}}"#
    static let directBindings = #"[{"source":"peril_direct","vhost":"/","destination":"pause_test","destination_type":"queue","routing_key":"pause","arguments":{},"properties_key":"pause"}]"#

    // MARK: HTTP responses: Linko's Grafana and Prometheus

    static let dashboardSearch = #"[{"id":1,"uid":"linko-app-metrics","orgId":1,"title":"Linko App Metrics","uri":"db/linko-app-metrics","url":"/d/linko-app-metrics/linko-app-metrics","slug":"","type":"dash-db","tags":["linko"],"isStarred":false,"sortMeta":0}]"#

    static let alertRules = #"""
        [{"id":1,"uid":"c7f2a1b9","orgID":1,"folderUID":"linko","ruleGroup":"Linko Group","title":"500 Error Spike","condition":"C","for":"20s","noDataState":"NoData","execErrState":"Error","data":[{"refId":"A","relativeTimeRange":{"from":600,"to":0},"datasourceUid":"prometheus","model":{"expr":"sum(rate(http_requests_total{status=\"500\"}[5m])) * 60","refId":"A"}},{"refId":"C","relativeTimeRange":{"from":0,"to":0},"datasourceUid":"__expr__","model":{"type":"threshold","expression":"A","refId":"C","conditions":[{"type":"query","evaluator":{"type":"gt","params":[3]},"operator":{"type":"and"},"reducer":{"type":"last","params":[]}}]}}]},{"id":2,"uid":"d8e3b2c0","orgID":1,"folderUID":"linko","ruleGroup":"Linko Group","title":"401 Login Failure Spike","condition":"C","for":"20s","noDataState":"NoData","execErrState":"Error","data":[{"refId":"A","relativeTimeRange":{"from":600,"to":0},"datasourceUid":"prometheus","model":{"expr":"sum(rate(http_requests_total{status=\"401\"}[5m])) * 60","refId":"A"}},{"refId":"C","relativeTimeRange":{"from":0,"to":0},"datasourceUid":"__expr__","model":{"type":"threshold","expression":"A","refId":"C","conditions":[{"type":"query","evaluator":{"type":"gt","params":[3]},"operator":{"type":"and"},"reducer":{"type":"last","params":[]}}]}}]}]
        """#

    static let firingRules = #"{"status":"success","data":{"groups":[{"name":"Linko Group","file":"linko","rules":[{"state":"firing","name":"500 Error Spike","query":"sum(rate(http_requests_total{status=\"500\"}[5m])) * 60 > 3","duration":20,"health":"ok","type":"alerting","lastEvaluation":"2026-10-31T10:40:10Z"},{"state":"firing","name":"401 Login Failure Spike","query":"sum(rate(http_requests_total{status=\"401\"}[5m])) * 60 > 3","duration":20,"health":"ok","type":"alerting","lastEvaluation":"2026-10-31T10:40:10Z"}],"interval":10}]}}"#

    static let gcQuery = #"{"status":"success","data":{"resultType":"vector","result":[{"metric":{"__name__":"go_gc_duration_seconds_count","instance":"host.docker.internal:8899","job":"linko"},"value":[1761907210.512,"14"]}]}}"#

    // MARK: HTTP responses: Tubely

    static let videoID = "8a1d6b2e-7c3f-4e95-b1a0-5d9e2c6f4b37"

    static func videos(thumbnail: String, landscape: String, portrait: String) -> String {
        #"[{"id":"\#(videoID)","created_at":"2026-10-31T12:01:44.552Z","updated_at":"2026-10-31T12:09:13.004Z","thumbnail_url":"\#(thumbnail)","video_url":"\#(landscape)","title":"Boots, an Emote Story","description":"A short film about the many faces of Boots, the Boot.dev bear","user_id":"\#(waltID)"},{"id":"3c9e7a51-2d4b-4f86-9e0a-7b1c5d3f8e29","created_at":"2026-10-31T12:12:05.118Z","updated_at":"2026-10-31T12:14:40.731Z","thumbnail_url":"\#(thumbnail)","video_url":"\#(portrait)","title":"Boots Goes Vertical","description":"The same bear, held the other way","user_id":"\#(waltID)"}]"#
    }

    static let videosServedByAPI = videos(
        thumbnail: "http://localhost:8091/api/thumbnails/\(videoID)",
        landscape: "http://localhost:8091/assets/\(videoID).mp4",
        portrait: "http://localhost:8091/assets/3c9e7a51.mp4"
    )
    static let videosWithDataThumbnails = videos(
        thumbnail: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
        landscape: "http://localhost:8091/assets/\(videoID).mp4",
        portrait: "http://localhost:8091/assets/3c9e7a51.mp4"
    )
    static let videosOnS3 = videos(
        thumbnail: "http://localhost:8091/assets/Qm3kV9xT2bLw8nR4cJ6yPa1sD5fG7hK0.png",
        landscape: "https://tubely-48213.s3.us-east-2.amazonaws.com/landscape/vT2nQ8mK4xR6bW1cY9sL3dF7.mp4",
        portrait: "https://tubely-48213.s3.us-east-2.amazonaws.com/portrait/hJ5gP0aZ8kU2eN6rX4wB1qM9.mp4"
    )
    static let videosPresigned = videos(
        thumbnail: "http://localhost:8091/assets/Qm3kV9xT2bLw8nR4cJ6yPa1sD5fG7hK0.png",
        landscape: "https://tubely-48213.s3.us-east-2.amazonaws.com/landscape/vT2nQ8mK4xR6bW1cY9sL3dF7.mp4?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAEXAMPLE%2F20261031%2Fus-east-2%2Fs3%2Faws4_request&X-Amz-Date=20261031T121500Z&X-Amz-Expires=300&X-Amz-SignedHeaders=host&X-Amz-Signature=5f0c2e7a9b1d4f6e8a3c5b7d9e1f2a4c6b8d0e2f4a6c8e0b2d4f6a8c0e2b4d6f",
        portrait: "https://tubely-48213.s3.us-east-2.amazonaws.com/portrait/hJ5gP0aZ8kU2eN6rX4wB1qM9.mp4?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Expires=300"
    )
    static let videosOnCloudFront = videos(
        thumbnail: "https://d1q7x2v9k3m8zp.cloudfront.net/assets/Qm3kV9xT2bLw8nR4cJ6yPa1sD5fG7hK0.png",
        landscape: "https://d1q7x2v9k3m8zp.cloudfront.net/landscape/vT2nQ8mK4xR6bW1cY9sL3dF7.mp4",
        portrait: "https://d1q7x2v9k3m8zp.cloudfront.net/portrait/hJ5gP0aZ8kU2eN6rX4wB1qM9.mp4"
    )

    static let video = #"{"id":"\#(videoID)","created_at":"2026-10-31T12:01:44.552Z","updated_at":"2026-10-31T12:09:13.004Z","thumbnail_url":"http://localhost:8091/api/thumbnails/\#(videoID)","video_url":null,"title":"Boots, an Emote Story","description":"A short film about the many faces of Boots, the Boot.dev bear","user_id":"\#(waltID)"}"#

    // MARK: HTTP responses: Bearly Secure

    static let health = #"{"ok":true,"app":"bearly-secure","version":"1.4.2"}"#

    /// /api/orders/1 before the lesson that hides internal fields: Go's field names, no tags.
    static let orderWithInternalFields = #"{"order":{"ID":1,"CustomerEmail":"mabel@example.com","ShippingName":"Mabel Pines","ShippingAddress":"618 Gopher Falls Rd","InternalNotes":"VIP: ships same day","TotalCents":4498,"Status":"paid","CreatedAt":"2026-10-31T10:21:09Z"},"items":[{"ProductID":3,"ProductName":"CORS Fox","Quantity":2,"PriceCents":1999},{"ProductID":5,"ProductName":"Classic Teddy","Quantity":1,"PriceCents":500}]}"#

    static let order = #"{"order":{"id":1,"status":"paid","total_cents":4498,"created_at":"2026-10-31T10:21:09Z"},"items":[{"product_id":3,"product_name":"CORS Fox","quantity":2,"price_cents":1999},{"product_id":5,"product_name":"Classic Teddy","quantity":1,"price_cents":500}]}"#

    static let orderNotFound = #"{"error":"Order not found"}"#

    static let accountOrders = #"{"orders":[{"id":1,"status":"paid","total_cents":4498,"created_at":"2026-10-31T10:21:09Z"},{"id":2,"status":"pending","total_cents":2499,"created_at":"2026-10-31T10:33:51Z"}]}"#

    static let products = #"{"products":[{"id":1,"name":"Classic Teddy","description":"The bear that started it all.","price_cents":2499,"image_path":"/static/img/classic-teddy.png"},{"id":2,"name":"SQLi Sloth","description":"Slowly drops your tables.","price_cents":1999,"image_path":"/static/img/sqli-sloth.png"},{"id":3,"name":"CORS Fox","description":"Only plays with allowed origins.","price_cents":1999,"image_path":"/static/img/cors-fox.png"},{"id":4,"name":"XSS Axolotl","description":"Escapes everything.","price_cents":2299,"image_path":"/static/img/xss-axolotl.png"},{"id":5,"name":"CSRF Ferret","description":"Carries a token everywhere.","price_cents":1899,"image_path":"/static/img/csrf-ferret.png"},{"id":6,"name":"OAuth Otter","description":"Asks before it shares.","price_cents":2199,"image_path":"/static/img/oauth-otter.png"},{"id":7,"name":"Rate Limit Raccoon","description":"Not so fast.","price_cents":1799,"image_path":"/static/img/rate-limit-raccoon.png"}]}"#

    static let warehouseOrders = #"{"integration":"Warehouse Fulfillment Integration","orders":[{"id":1,"status":"paid","total_cents":4498,"created_at":"2026-10-31T10:21:09Z"},{"id":2,"status":"paid","total_cents":2499,"created_at":"2026-10-31T10:33:51Z"}]}"#

    static let passkeyChallenge = #"{"challengeId":"6f3c1a9e-2b7d-4e5f-8a0c-9d1e3f5a7b2c","publicKey":{"challenge":"q2-3V0bXk9sR7tY1uI8oP4aS6dF2gH5jK0lZ3xC7vB1","timeout":60000,"rpId":"localhost","allowCredentials":[],"userVerification":"required"}}"#
}
