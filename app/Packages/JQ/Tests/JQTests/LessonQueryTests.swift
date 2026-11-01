import JQ
import Testing

/// What a lesson expects of a query's output.
enum Expected: Sendable {
    /// One output equal to this: the lessons' `==` and `eq`.
    case equals(JQValue)
    /// One number greater than this: `>` and `gt`.
    case greaterThan(Int)
    /// One number at least this: `>=`.
    case atLeast(Int)
    /// One string containing this: `contains`.
    case contains(String)
    /// One string without this: `not_contains`.
    case lacks(String)
}

/// A lesson's query with a realistic input and the answer the lesson expects.
struct LessonCase: Sendable, CustomTestStringConvertible {
    let query: String
    let mode: JQInputMode
    let input: String
    let expected: Expected

    var testDescription: String {
        query
    }

    static func json(_ query: String, _ input: String, _ expected: Expected) -> LessonCase {
        LessonCase(query: query, mode: .json, input: input, expected: expected)
    }

    static func jsonl(_ query: String, _ input: String, _ expected: Expected) -> LessonCase {
        LessonCase(query: query, mode: .jsonl, input: input, expected: expected)
    }

    func verify() throws {
        let outputs = try JQProgram(query).run(JQValue(json: input, mode: mode))
        switch expected {
        case .equals(let value):
            #expect(outputs == [value])
        case .greaterThan(let bound):
            let number = try #require(Self.number(outputs))
            #expect(number > Double(bound))
        case .atLeast(let bound):
            let number = try #require(Self.number(outputs))
            #expect(number >= Double(bound))
        case .contains(let text):
            let string = try #require(Self.string(outputs))
            #expect(string.contains(text))
        case .lacks(let text):
            let string = try #require(Self.string(outputs))
            #expect(!string.contains(text))
        }
    }

    private static func number(_ outputs: [JQValue]) -> Double? {
        guard outputs.count == 1, case .number(let number) = outputs[0] else {
            return nil
        }
        return number.doubleValue
    }

    private static func string(_ outputs: [JQValue]) -> String? {
        guard outputs.count == 1, case .string(let string) = outputs[0] else {
            return nil
        }
        return string
    }
}

extension JQTests {
    /// Every jq query in the lessons: command-line output tests, HTTP captures and HTTP tests.
    @Suite("Lesson queries")
    struct LessonQueries {
        @Test("Check program reports", arguments: Lessons.checkReports)
        func checkReport(_ query: String) throws {
            let program = try JQProgram(query)
            let fields = query.matches(of: /\.([A-Za-z][A-Za-z0-9]*)/).map { String($0.1) }
            try #require(!fields.isEmpty)
            // The check programs print one boolean per property, true when it holds.
            func report(failing: String?) throws -> JQValue {
                try JQValue(json: "{" + fields.map { #""\#($0)":\#($0 != failing)"# }.joined(separator: ",") + "}")
            }
            #expect(try program.run(report(failing: nil)) == [true])
            for field in fields {
                #expect(try program.run(report(failing: field)) == [false], "with \(field) false")
            }
        }

        @Test("Command-line output tests", arguments: Lessons.commandLine)
        func commandLine(_ lesson: LessonCase) throws {
            try lesson.verify()
        }

        @Test("HTTP response captures", arguments: Lessons.captures)
        func capture(_ lesson: LessonCase) throws {
            try lesson.verify()
        }

        @Test("HTTP JSON tests", arguments: Lessons.httpTests)
        func httpTest(_ lesson: LessonCase) throws {
            try lesson.verify()
        }
    }
}

enum Lessons {
    /// stdoutJq queries over the reports of `go run ./lessonchecks/...`, which all pass when
    /// every named property is true.
    static let checkReports: [String] = [
        #".argon2idBaselineUsed and .freshSaltsUsed and .correctPasswordWorks and .wrongPasswordRejected and .legacyHashSupported and .malformedHashRejected and .unsupportedVersionRejected and .unsafeParametersRejected and .passwordLimitPreserved"#,
        #".atomicSingleUse"#,
        #".authenticationPrecedesQuota and .concurrentQuotaBounded and .exhaustedRequestsRejected and .quotaMetadataValid and .usagePersistedAtLimit"#,
        #".authenticationStatusesValid and .requestIdsGlobal and .requestIdsServerGenerated and .authEventsCorrelated and .authSecretsAbsent"#,
        #".backupCodeAcceptedOnce and .backupCodeConsumed"#,
        #".currentHashAccepted and .legacyHashNeedsRehash and .staleHashNeedsRehash and .successfulLoginUpgraded and .failedLoginPreservedHash and .mfaRecoveryUpgraded"#,
        #".downloadKeyRequired and .invalidDownloadKeyDenied and .dotenvLoaded and .processEnvironmentWins and .configuredDownloadKeyUsed"#,
        #".encryptionPolicySatisfied"#,
        #".endpointAllowanceEnforced and .publicCORSRetained and .normalProductsRetained and .globalAllowanceRetained"#,
        #".exactHttpsOriginAllowed and .unsafeDestinationsDenied and .proxyDisabled and .redirectsDisabled and .fiveSecondDeadlines and .redirectRejectedUnread"#,
        #".expired"#,
        #".failedLoginAlertAtThreshold and .passwordResetAlertAtThreshold and .successfulLoginIgnored and .failedTotpCounted and .knownResetCounted and .loginAlert and .resetAlert"#,
        #".fixedWindowBehavior and .globalAllowanceEnforced and .clientIsolationMaintained and .healthExcluded"#,
        #".invalidKeyRejected and .invalidKeyLeftOrderPending and .malformedPayloadRejected and .malformedPayloadLeftOrderPending and .unapprovedStatusRejected and .unapprovedStatusLeftOrderPending and .approvedWebhookAccepted and .orderMarkedPaid"#,
        #".jsonResponseSafe and .errorPageSafe and .diagnosticsRetained and .clientErrorsPreserved"#,
        #".keyManagementPolicySatisfied"#,
        #".normalArchiveExtracted and .insideNormalizationWorks and .traversalRejected and .noEscapeOrPartialWrites and .absolutePathRejected and .backslashPathRejected and .symlinkRejected"#,
        #".oneExpiresField and .expiresIsRfc3339 and .expiresIsFuture and .expiresWithinOneYear"#,
        #".onlyStatusToolAvailable and .refundDenied"#,
        #".optionsValidated and .excessWorkRejected and .capacityRecoveredAfterReturn and .capacityRecoveredAfterPanic and .applicationMounted and .healthExcluded"#,
        #".pawPalKeyRequired and .pawPalKeyInjected"#,
        #".pendingChallengeExists"#,
        #".requestBodiesBounded and .individualUploadBounded and .archiveUploadBounded and .singleFileUploadsEnforced and .publicProductResultsBounded"#,
        #".rotatingCallersShareThrottle and .throttleMetadataValid and .normalSearchAvailableAfterReset"#,
        #".seededDocumentEncrypted and .seededDocumentReadable and .individualUploadEncrypted and .individualUploadReadable and .archiveImportEncrypted and .archiveImportReadable and .tamperedDocumentRejected and .fixturePolicyPreserved"#,
        #".seededKeyStoredAsHash"#,
        #".sensitiveFieldsRedacted and .usefulFieldsPreserved and .rawSecretsAbsent"#,
        #".sensitiveFilesExcluded and .generatedDataExcluded and .requiredBuildInputsIncluded"#,
        #".serverTimeoutsConfigured and .timeoutResponseRetryable and .checkoutStatePreserved"#,
        #".shippingEncryptedAtRest and .internalNotesExcludePII and .centralPolicyRedactsPII"#,
        #".siteAddressConfigured and .automaticHttpsEnabled and .reverseProxyConfigured and .hstsConfigured and .environmentDocumented and .configuredHopCountExact and .negativeHopCountRejected and .serverWiringConfigured"#,
        #".systemInstructionsSeparated and .customerMessageSeparated and .originalToolsPreserved"#,
        #".unsupportedRejectedWithoutSideEffects and .acceptedTypesClassified and .safeStorageNames and .validUploadsStored and .archiveImportsClassified"#,
        #".validCodeAccepted and .replayRejected and .singleConsumptionRecorded"#,
        #".whitespaceRejected and .oversizedRejected and .boundaryAcceptedAndTrimmed"#,
    ]

    /// The other stdoutJq queries: Go's environment, structured reports, and the courses'
    /// JSON-lines logs.
    static let commandLine: [LessonCase] = [
        .json(#".GOVERSION | [scan("[0-9]+") | tonumber] | .[1] > 27 or (.[1] == 27 and .[2] >= 2)"#, Fixture.goEnv("go1.27.3"), .equals(true)),
        .json(#".hashMatches == true and .rawTokenStored == false and .expiresAboutFifteenMinutes == true"#, Fixture.resetTokenReport, .equals(true)),
        .json(#".knownLoginStatuses == [401, 401, 401, 401, 401, 429] and .unknownLoginStatuses == [401, 401, 401, 401, 401, 429] and (.loginIpStatuses[0:20] | all(. == 401)) and .loginIpStatuses[20] == 429 and (.totpIpStatuses[0:20] | all(. == 302)) and .totpIpStatuses[20] == 429 and .knownResetStatuses == [200, 200, 200, 429] and .unknownResetStatuses == [200, 200, 200, 429] and (.resetIpStatuses[0:10] | all(. == 200)) and .resetIpStatuses[10] == 429 and .loginLimitBodiesMatch and .resetLimitBodiesMatch and .resetNeutralBodiesMatch and .blockedAttemptsHaveRetryAfter"#, Fixture.authRateLimitsReport, .equals(true)),
        .json(#".revoked == 3 and (.oldSessionActive | not) and (.boundarySessionActive | not) and (.newSessionActive | not) and .revocationTimestampMatchesDatabaseClock and .alreadyRevokedSessionUnchanged and .repeatRevocationNoChanges"#, Fixture.revokedSessionsReport, .equals(true)),
        .json(#".pendingChallengeExists"#, #"{"pendingChallengeExists":true,"challengeId":17}"#, .equals(true)),
        .json(#".pendingChallengeExists"#, #"{"pendingChallengeExists":false}"#, .equals(false)),

        .jsonl(#".[] | select(.msg == "error validating password") | .error.stack_trace | length"#, Fixture.linkoAccessLog, .greaterThan(0)),
        .jsonl(#".[] | select(.msg == "failed to list URLs") | .error.path"#, Fixture.linkoListLog, .equals("data/BADENTRY")),
        .jsonl(#".[] | select(.msg == "failed to list URLs") | .errors | map(.path) | sort | join(", ")"#, Fixture.linkoJoinedErrorsLog, .equals("data/BADENTRY1, data/BADENTRY2")),
        .jsonl(#".[] | select(.msg == "failed to list URLs") | .errors.error_1 != null"#, Fixture.linkoJoinedErrorsLog, .equals(true)),
        .jsonl(#".[] | select(.msg == "failed to list URLs") | .errors.error_2 != null"#, Fixture.linkoJoinedErrorsLog, .equals(true)),
        .jsonl(#"[.[] | select(.msg == "Successfully generated short code")] | length"#, Fixture.linkoAccessLog, .equals(1)),
        .jsonl(#"[.[] | select(.msg == "error validating password")] | any(.user == "saruman")"#, Fixture.linkoAccessLog, .equals(true)),
        .jsonl(#"[.[] | select(.msg == "error validating password")] | length"#, Fixture.linkoAccessLog, .equals(1)),
        .jsonl(#"[.[] | select(.msg | contains("Parsed URL") or contains("Shortening URL"))] | length"#, Fixture.linkoAccessLog, .equals(0)),
        .jsonl(#"all(.[]; .env == "development")"#, Fixture.linkoAccessLog, .equals(true)),
        .jsonl(#"any(.[] | .msg; contains("failed to read"))"#, Fixture.linkoLookupLog, .equals(false)),
        .jsonl(#"any(.[] | .msg; contains("read data/BADENTRY"))"#, Fixture.linkoListLog, .equals(false)),
        .jsonl(#"any(.[] | select(.msg == "Served request" and .path == "/"); .client_ip == "127.0.0.x")"#, Fixture.linkoAccessLog, .equals(true)),
        .jsonl(#"any(.[] | select(.msg == "Served request" and .path == "/api/login" and .response_status == 200); .user == "[REDACTED]")"#, Fixture.linkoAccessLog, .equals(true)),
        .jsonl(#"any(.[] | select(.msg == "Served request" and .path == "/api/login" and .response_status == 200); .user == null)"#, Fixture.linkoAccessLog, .equals(false)),
        .jsonl(#"any(.[] | select(.msg == "Served request" and .path == "/api/login" and .response_status == 401); .error.message == "unauthorized")"#, Fixture.linkoAccessLog, .equals(true)),
        .jsonl(#"any(.[] | select(.msg == "Served request" and .path == "/api/login" and .response_status == 401); .user != null)"#, Fixture.linkoAccessLog, .equals(false)),
        .jsonl(#"any(.[] | select(.msg == "Served request" and .path == "/api/login" and .response_status == 500); .error == null)"#, Fixture.linkoAccessLog, .equals(false)),
        .jsonl(#"any(.[] | select(.msg == "Served request" and .path == "/api/login" and .response_status == 500); .error.stack_trace == null)"#, Fixture.linkoAccessLog, .equals(false)),
        .jsonl(#"any(.[] | select(.msg == "Served request" and .path == "/api/shorten" and .response_status == 400); .error.message | contains("invalid URL"))"#, Fixture.linkoAccessLog, .equals(true)),
        .jsonl(#"any(.[] | select(.msg == "Served request" and .path == "/not-real" and .response_status == 404); .error.message == "not found")"#, Fixture.linkoAccessLog, .equals(true)),
        .jsonl(#"any(.[] | select(.msg == "Served request"); .duration > 0)"#, Fixture.linkoAccessLog, .equals(true)),
        .jsonl(#"any(.[] | select(.msg == "Served request"); .request_body_bytes >= 0)"#, Fixture.linkoAccessLog, .equals(true)),
        .jsonl(#"any(.[] | select(.msg == "Served request"); .response_body_bytes > 0)"#, Fixture.linkoAccessLog, .equals(true)),
        .jsonl(#"any(.[] | select(.msg == "Served request"); .response_status == 500)"#, Fixture.linkoAccessLog, .equals(true)),
        .jsonl(#"any(.[] | select(.msg == "Successfully generated short code"); .long_url | contains("REDACTED"))"#, Fixture.linkoAccessLog, .equals(true)),
        .jsonl(#"any(.[] | select(.msg == "error validating password") | .error; contains("main.(*server).validatePassword"))"#, Fixture.linkoStackTextLog, .equals(true)),
        .jsonl(#"any(.[] | select(.msg == "failed to lookup URL") | .error; contains("data/WTF"))"#, Fixture.linkoLookupLog, .equals(true)),
        .jsonl(#"any(.[]; .event == "account_accessed" and .userId != null and .email == "grenda@example.com" and .expiresAt != null and .sessionId == null and .sessionToken == null)"#, Fixture.bearlySecureLog, .equals(true)),
        .jsonl(#"any(.[]; .event == "checkout_started" and .email == "[REDACTED]" and .shippingName == "[REDACTED]" and .shippingAddress == "[REDACTED]" and .shippingCity == "[REDACTED]" and .shippingRegion == "[REDACTED]" and .shippingPostalCode == "[REDACTED]" and (.userId | type) == "number" and (.orderId | type) == "number" and (.totalCents | type) == "number")"#, Fixture.bearlySecureLog, .equals(true)),
        .jsonl(#"any(.[]; .event == "login_attempt" and .email == "[REDACTED]" and (.userId | type) == "number" and .success == true)"#, Fixture.bearlySecureLog, .equals(true)),
        .jsonl(#"any(.[]; .event == "password_reset_request" and .email == "grenda@example.com" and .success == true and .resetLink != null)"#, Fixture.bearlySecureLog, .equals(true)),
        .jsonl(#"any(.[]; .hostname == null)"#, Fixture.linkoAccessLog, .equals(false)),
        .jsonl(#"any(.[]; .msg == "Served request" and .path == "/" and .request_id != null and .request_id != "")"#, Fixture.linkoAccessLog, .equals(true)),
        .jsonl(#"any(.[]; .msg == "Served request" and .path == "/" and .request_id == "bootdev-test-id")"#, Fixture.linkoAccessLog, .equals(true)),
        .jsonl(#"any(.[]; .msg == "Served request" and .path == "/" and .user != null)"#, Fixture.linkoAccessLog, .equals(false)),
        .jsonl(#"any(.[]; .msg == "Served request" and .path == "/")"#, Fixture.linkoAccessLog, .equals(true)),
        .jsonl(#"any(.[]; .msg == "Served request" and .path == "/api/login" and .response_status == 200)"#, Fixture.linkoAccessLog, .equals(true)),
        .jsonl(#"any(.[]; .msg == "Served request" and .path == "/api/login" and .response_status == 401)"#, Fixture.linkoAccessLog, .equals(true)),
        .jsonl(#"any(.[]; .msg == "Served request" and .path == "/api/login" and .response_status == 500)"#, Fixture.linkoAccessLog, .equals(true)),
        .jsonl(#"any(.[]; .msg == "Served request" and .path == "/not-real" and .response_status == 404)"#, Fixture.linkoAccessLog, .equals(true)),
        .jsonl(#"any(.[]; .msg == "Served request")"#, Fixture.linkoAccessLog, .equals(true)),
        .jsonl(#"any(.[]; .msg == "error validating password" and .build_time != null and .build_time != "unknown")"#, Fixture.linkoAccessLog, .equals(true)),
        .jsonl(#"any(.[]; .msg == "error validating password" and .git_sha != null and .git_sha != "unknown")"#, Fixture.linkoAccessLog, .equals(true)),
        .jsonl(#"any(.[]; .msg == "error validating password")"#, Fixture.linkoAccessLog, .equals(true)),
        .jsonl(#"any(.[]; .msg == "error validating password")"#, Fixture.linkoStackTextLog, .equals(true)),
        .jsonl(#"any(.[]; .msg == "failed to list URLs")"#, Fixture.linkoListLog, .equals(true)),
        .jsonl(#"any(.[]; .msg == "failed to list URLs")"#, Fixture.linkoJoinedErrorsLog, .equals(true)),
        .jsonl(#"any(.[]; .msg == "failed to lookup URL")"#, Fixture.linkoLookupLog, .equals(true)),
        .jsonl(#"length"#, Fixture.linkoAccessLog, .atLeast(3)),
    ]

    /// responseVariables paths: values captured from a response for later steps.
    static let captures: [LessonCase] = [
        .json(#".[0].id"#, Fixture.videosOnCloudFront, .equals(.string(Fixture.videoID))),
        .json(#".[0].thumbnail_url"#, Fixture.videosServedByAPI, .equals(.string("http://localhost:8091/api/thumbnails/\(Fixture.videoID)"))),
        .json(#".[0].video_url"#, Fixture.videosOnS3, .equals("https://tubely-48213.s3.us-east-2.amazonaws.com/landscape/vT2nQ8mK4xR6bW1cY9sL3dF7.mp4")),
        .json(#".[1].video_url"#, Fixture.videosOnS3, .equals("https://tubely-48213.s3.us-east-2.amazonaws.com/portrait/hJ5gP0aZ8kU2eN6rX4wB1qM9.mp4")),
        .json(#".challengeId"#, Fixture.passkeyChallenge, .equals("6f3c1a9e-2b7d-4e5f-8a0c-9d1e3f5a7b2c")),
        .json(#".id"#, Fixture.createdUser, .equals(.string(Fixture.waltID))),
        .json(#".publicKey.challenge"#, Fixture.passkeyChallenge, .equals("q2-3V0bXk9sR7tY1uI8oP4aS6dF2gH5jK0lZ3xC7vB1")),
        .json(#".publicKey.rpId"#, Fixture.passkeyChallenge, .equals("localhost")),
        .json(#".refresh_token"#, Fixture.login, .equals("9c4e1f7a2b8d3e6f0a5c9b2d7e1f4a8c3b6d0e9f2a5c8b1d4e7f0a3c6b9d2e5f")),
        .json(#".token"#, Fixture.login, .equals("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJjaGlycHktYWNjZXNzIiwic3ViIjoiN2QyZTlmNDEiLCJleHAiOjE3NjE5MTE0MDB9.mQ3cYk2uBq0n8p1xZr7tV5wJ4sD6fH9gL3aE0iO2uT8")),
        .json(#"first(.[] | select(.title == "Linko App Metrics")).uid"#, Fixture.dashboardSearch, .equals("linko-app-metrics")),
    ]

    /// jsonValue paths of HTTP steps' tests.
    static let httpTests: [LessonCase] = [
        .json(#"((.order | keys | sort) == ["created_at", "id", "status", "total_cents"]) and (.order.id == 1) and all(.items[];\#n  ((keys | sort) == ["price_cents", "product_id", "product_name", "quantity"]))"#, Fixture.order, .equals(true)),
        .json(#". | length"#, Fixture.dashboardSearch, .greaterThan(0)),
        .json(#".[0].body"#, Fixture.chirpsAscending, .equals("I'm the one who knocks!")),
        .json(#".[0].body"#, Fixture.chirpsDescending, .equals("Darn that fly, I just wanna cook")),
        .json(#".[0].body"#, Fixture.chirps(["If you're committed enough, you can make any story work.", "I once told a woman I was Kevin Costner, and it worked because I believed it."]), .equals("If you're committed enough, you can make any story work.")),
        .json(#".[0].description"#, Fixture.videosOnCloudFront, .contains("A short film about the many faces of Boots")),
        .json(#".[0].destination"#, Fixture.directBindings, .equals("pause_test")),
        .json(#".[0].routing_key"#, Fixture.directBindings, .equals("pause")),
        .json(#".[0].thumbnail_url"#, Fixture.videosServedByAPI, .contains("/api/thumbnails")),
        .json(#".[0].thumbnail_url"#, Fixture.videosOnS3, .contains("/assets/")),
        .json(#".[0].thumbnail_url"#, Fixture.videosWithDataThumbnails, .contains("data:image/")),
        .json(#".[0].thumbnail_url"#, Fixture.videosOnS3, .lacks(Fixture.videoID)),
        .json(#".[0].title"#, Fixture.videosOnCloudFront, .contains("Boots, an Emote Story")),
        .json(#".[0].video_url"#, Fixture.videosOnS3, .contains("/landscape/")),
        .json(#".[0].video_url"#, Fixture.videosOnS3, .contains("amazonaws.com")),
        .json(#".[0].video_url"#, Fixture.videosPresigned, .contains("X-Amz-Algorithm")),
        .json(#".[0].video_url"#, Fixture.videosOnCloudFront, .contains("cloudfront.net")),
        .json(#".[1].body"#, Fixture.chirpsAscending, .equals("Gale!")),
        .json(#".[1].body"#, Fixture.chirpsDescending, .equals("Cmon Pinkman")),
        .json(#".[1].video_url"#, Fixture.videosOnCloudFront, .contains("/portrait/")),
        .json(#".[2].body"#, Fixture.chirpsAscending, .equals("Cmon Pinkman")),
        .json(#".[2].body"#, Fixture.chirpsDescending, .equals("Gale!")),
        .json(#".[3].body"#, Fixture.chirpsAscending, .equals("Darn that fly, I just wanna cook")),
        .json(#".[3].body"#, Fixture.chirpsDescending, .equals("I'm the one who knocks!")),
        .json(#".app"#, Fixture.health, .equals("bearly-secure")),
        .json(#".auto_delete"#, Fixture.gameLogsQueue, .equals(false)),
        .json(#".auto_delete"#, Fixture.sunTzuPauseQueue, .equals(true)),
        .json(#".body"#, Fixture.chirp, .equals("I'm gonna be a damn good developer, and people are gonna know about it.")),
        .json(#".cleaned_body"#, #"{"cleaned_body":"I hear Mastodon is better than Chirpy. **** I need to migrate"}"#, .equals("I hear Mastodon is better than Chirpy. **** I need to migrate")),
        .json(#".data.result | length"#, Fixture.gcQuery, .greaterThan(0)),
        .json(#".data.result[0].metric.job"#, Fixture.gcQuery, .equals("linko")),
        .json(#".durable"#, Fixture.gameLogsQueue, .equals(true)),
        .json(#".durable"#, Fixture.sunTzuPauseQueue, .equals(false)),
        .json(#".email"#, Fixture.createdUser, .equals("walt@breakingbad.com")),
        .json(#".email"#, Fixture.updatedUser, .equals("walter@breakingbad.com")),
        .json(#".email"#, Fixture.login, .equals("saul@bettercall.com")),
        .json(#".error"#, Fixture.orderNotFound, .equals("Order not found")),
        .json(#".exclusive"#, Fixture.sunTzuPauseQueue, .equals(true)),
        .json(#".id"#, Fixture.video, .equals(.string(Fixture.videoID))),
        .json(#".integration"#, Fixture.warehouseOrders, .equals("Warehouse Fulfillment Integration")),
        .json(#".integration == "Warehouse Fulfillment Integration" and (.orders | length) > 0 and all(.orders[]; ((keys | sort) == ["created_at", "id", "status", "total_cents"])) and any(.orders[]; .id == 1 and .total_cents == 4498)"#, Fixture.warehouseOrders, .equals(true)),
        .json(#".is_chirpy_red"#, Fixture.createdUser, .equals(false)),
        .json(#".is_chirpy_red"#, Fixture.login, .equals(true)),
        .json(#".message_stats.deliver_get"#, Fixture.washingtonPauseQueue, .greaterThan(1)),
        .json(#".message_stats.drop_unroutable"#, Fixture.overview, .greaterThan(0)),
        .json(#".message_stats.publish"#, Fixture.overview, .greaterThan(0)),
        .json(#".message_stats.publish"#, Fixture.washingtonPauseQueue, .greaterThan(1)),
        .json(#".message_stats.redeliver"#, Fixture.warQueue, .greaterThan(100)),
        .json(#".messages_ready"#, Fixture.drainedGameLogsQueue, .equals(0)),
        .json(#".messages_ready"#, Fixture.gameLogsQueue, .greaterThan(2)),
        .json(#".messages_ready"#, Fixture.readyColumn, .greaterThan(499)),
        .json(#".messages_ready"#, Fixture.pauseTestQueue, .greaterThan(0)),
        .json(#".messages_ready"#, Fixture.deadLetterQueue, .greaterThan(0)),
        .json(#".ok"#, Fixture.health, .equals(true)),
        .json(#".order.CustomerEmail"#, Fixture.orderWithInternalFields, .equals("mabel@example.com")),
        .json(#".order.ID"#, Fixture.orderWithInternalFields, .equals(1)),
        .json(#".orders | length"#, Fixture.warehouseOrders, .greaterThan(0)),
        .json(#".product_name"#, Fixture.overview, .equals("RabbitMQ")),
        .json(#".status"#, Fixture.gcQuery, .equals("success")),
        .json(#".type"#, Fixture.directExchange, .equals("direct")),
        .json(#".type"#, Fixture.topicExchange, .equals("topic")),
        .json(#".user_id"#, Fixture.chirp, .equals(.string(Fixture.saulID))),
        .json(#".valid"#, #"{"valid":true}"#, .equals(true)),
        .json(#"all(.orders[]; ((keys | sort) == ["created_at", "id", "status", "total_cents"]))"#, Fixture.accountOrders, .equals(true)),
        .json(#"all(.products[]; ((keys | sort) == ["description", "id", "image_path", "name", "price_cents"])) and ([.products[].name] | sort) == ["CORS Fox", "CSRF Ferret", "Classic Teddy", "OAuth Otter", "Rate Limit Raccoon", "SQLi Sloth", "XSS Axolotl"]"#, Fixture.products, .equals(true)),
        .json(#"any(.[]; .title == "401 Login Failure Spike")"#, Fixture.alertRules, .equals(true)),
        .json(#"any(.[]; .title == "500 Error Spike")"#, Fixture.alertRules, .equals(true)),
        .json(#"any(.[]; .title == "Linko App Metrics")"#, Fixture.dashboardSearch, .equals(true)),
        .json(#"any(.data.groups[]?.rules[]?; .name == "401 Login Failure Spike" and .state == "firing")"#, Fixture.firingRules, .equals(true)),
        .json(#"any(.data.groups[]?.rules[]?; .name == "500 Error Spike" and .state == "firing")"#, Fixture.firingRules, .equals(true)),
        .json(#"first(.[] | select(.title == "401 Login Failure Spike")).data[0].model.expr"#, Fixture.alertRules, .equals(#"sum(rate(http_requests_total{status="401"}[5m])) * 60"#)),
        .json(#"first(.[] | select(.title == "401 Login Failure Spike")).data[1].model.conditions[0].evaluator.params[0]"#, Fixture.alertRules, .equals(3)),
        .json(#"first(.[] | select(.title == "401 Login Failure Spike")).ruleGroup"#, Fixture.alertRules, .equals("Linko Group")),
        .json(#"first(.[] | select(.title == "500 Error Spike")).data[0].model.expr"#, Fixture.alertRules, .equals(#"sum(rate(http_requests_total{status="500"}[5m])) * 60"#)),
        .json(#"first(.[] | select(.title == "500 Error Spike")).data[1].model.conditions[0].evaluator.params[0]"#, Fixture.alertRules, .equals(3)),
        .json(#"first(.[] | select(.title == "500 Error Spike")).for"#, Fixture.alertRules, .equals("20s")),
        .json(#"first(.[] | select(.title == "500 Error Spike")).ruleGroup"#, Fixture.alertRules, .equals("Linko Group")),
    ]
}
