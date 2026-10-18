import Foundation
@testable import Logger
import Testing

@Suite("Logger privacy projection")
struct LoggerPrivacyProjectionTests {
  private struct SentinelError: LocalizedError {
    var errorDescription: String? {
      "localized-error-sentinel"
    }
  }

  private struct CategorizedError: PrivacySafeErrorCategoryProviding {
    let privacySafeErrorCategory: String
  }

  @Test("scrubbed projection keeps the message and error but drops sensitive values")
  func scrubbedProjectionKeepsUsefulDetails() throws {
    let entry = Log.makeEntry(
      level: .error,
      scope: "scope/user@example.com",
      message: "sync failed for chat 42 user=person@example.com token=abc123secret",
      error: SentinelError(),
      source: LogSourceLocation(
        file: "/Users/someone/dev/Feature.swift",
        function: "performRequest()",
        line: 42
      ),
      detail: .scrubbed
    )
    let encoded = try JSONEncoder().encode(entry)
    let text = try #require(String(data: encoded, encoding: .utf8))

    for sentinel in ["person@example.com", "abc123secret", "someone", "scope/user"] {
      #expect(!text.contains(sentinel))
    }
    #expect(entry.message.contains("sync failed for chat 42"))
    #expect(entry.message.contains("[Feature.swift:42 performRequest()]"))
    #expect(entry.message.contains("localized-error-sentinel"))
    #expect(try #require(entry.error).contains("SentinelError"))
    #expect(entry.scope == "app")
    #expect(entry.file == "Feature.swift")
    #expect(entry.detail == .scrubbed)
  }

  @Test("scrubbed projection retains only bounded static scopes")
  func scrubbedProjectionSanitizesScope() {
    for scope in ["ApiClient", "FullChat", "realtime.v2", "file_upload"] {
      let entry = Log.makeEntry(
        level: .error,
        scope: scope,
        message: "request failed",
        error: nil,
        source: LogSourceLocation(file: "Feature.swift", function: "work()", line: 1),
        detail: .scrubbed
      )
      #expect(entry.scope == scope)
    }

    for scope in ["user/person@example.com", "private scope", String(repeating: "a", count: 65)] {
      let entry = Log.makeEntry(
        level: .error,
        scope: scope,
        message: "request failed",
        error: nil,
        source: LogSourceLocation(file: "Feature.swift", function: "work()", line: 1),
        detail: .scrubbed
      )
      #expect(entry.scope == "app")
    }
  }

  @Test("scrubber removes common secrets and keeps identifiers")
  func scrubberRemovesSecrets() {
    let uuid = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
    let scrubbed = LogScrubber.scrub(
      "GET https://user:pw@api.inline.chat/v1/getChat?token=xyz&q=hi id=\(uuid) "
        + "Authorization: Bearer abc.def.ghi call +1 (415) 555-0100 "
        + "key \(String(repeating: "a1", count: 20)) path /Users/jane/Library/x chat 12345"
    )

    #expect(scrubbed.contains("https://api.inline.chat/v1/getChat"))
    #expect(!scrubbed.contains("token=xyz"))
    #expect(!scrubbed.contains("user:pw"))
    #expect(!scrubbed.contains("abc.def.ghi"))
    #expect(!scrubbed.contains("555-0100"))
    #expect(!scrubbed.contains("a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"))
    #expect(!scrubbed.contains("jane"))
    #expect(scrubbed.contains(uuid))
    #expect(scrubbed.contains("chat 12345"))
  }

  @Test("scrubber bounds message length")
  func scrubberBoundsLength() {
    let scrubbed = LogScrubber.scrub(String(repeating: "word ", count: 1_000))
    #expect(scrubbed.count <= LogScrubber.maxLength + 1)
  }

  @Test("error category keeps finite URL error grouping")
  func errorCategoryGroupsURLErrors() {
    #expect(Log.errorCategory(URLError(.timedOut)) == "url:\(URLError(.timedOut).errorCode)")
    #expect(Log.errorCategory(SentinelError()) == "other")
    #expect(Log.errorCategory(nil) == nil)
  }

  @Test("error category retains only explicit bounded categories")
  func errorCategoryRetainsExplicitCategories() {
    #expect(
      Log.errorCategory(CategorizedError(privacySafeErrorCategory: "realtime_rpc:application:2:401"))
        == "realtime_rpc:application:2:401"
    )
    #expect(Log.errorCategory(CategorizedError(privacySafeErrorCategory: "person@example.com")) == "other")
    #expect(Log.errorCategory(CategorizedError(privacySafeErrorCategory: String(repeating: "a", count: 97))) == "other")
  }

  @Test("full projection retains local diagnostics")
  func fullProjectionRetainsDetails() {
    let entry = Log.makeEntry(
      level: .info,
      scope: "local-scope",
      message: "local-message person@example.com",
      error: nil,
      source: LogSourceLocation(file: "/tmp/Feature.swift", function: "work()", line: 9),
      detail: .full
    )

    #expect(entry.scope == "local-scope")
    #expect(entry.message.contains("local-message person@example.com"))
    #expect(entry.file == "/tmp/Feature.swift")
  }

  @Test("full entries are scrubbed before leaving the device")
  func fullEntryScrubsForSentry() {
    let entry = Log.makeEntry(
      level: .error,
      scope: "user/person@example.com",
      message: "failed for person@example.com",
      error: nil,
      source: LogSourceLocation(file: "/Users/someone/Feature.swift", function: "work()", line: 3),
      detail: .full
    ).scrubbed()

    #expect(entry.detail == .scrubbed)
    #expect(entry.scope == "app")
    #expect(entry.file == "Feature.swift")
    #expect(entry.message.contains("failed for <email>"))
  }

  @Test("build flavor and override choose the local projection")
  func buildFlavorChoosesProjection() {
    #expect(Log.localDetail(isDebugBuild: true, unredactedLocalLogs: false) == .full)
    #expect(Log.localDetail(isDebugBuild: false, unredactedLocalLogs: false) == .scrubbed)
    #expect(Log.localDetail(isDebugBuild: false, unredactedLocalLogs: true) == .full)
  }

  @Test("HTTP diagnostics allow only templates and finite metadata")
  func httpDiagnosticsAreStructurallyPrivate() throws {
    let diagnostic = try #require(HTTPLogMetadata(
      method: "post",
      endpointTemplate: "/v1/verifyEmailCode",
      statusCode: 429,
      requestID: "request-123",
      responseBytes: 812,
      apiErrorCode: 7
    ))

    #expect(diagnostic.method == "POST")
    #expect(diagnostic.requestID == "request-123")
    #expect(diagnostic.consoleMessage == "event=http.request_failed method=POST endpoint=/v1/verifyEmailCode status=429 request_id=request-123 response_bytes=812 api_error_code=7")
    #expect(HTTPLogMetadata(
      method: "GET",
      endpointTemplate: "/v1/search?q=person@example.com",
      statusCode: 500
    ) == nil)
  }

  @Test("Sentry HTTP policy skips rate limits and separates endpoints")
  func sentryHTTPPolicy() throws {
    let rateLimit = try #require(HTTPLogMetadata(
      method: "POST",
      endpointTemplate: "/v1/verifyEmailCode",
      statusCode: 429
    ))
    #expect(!SentryLogPolicy.shouldReport(http: rateLimit))

    let failure = try #require(HTTPLogMetadata(
      method: "GET",
      endpointTemplate: "/v1/getMe",
      statusCode: 500
    ))
    #expect(SentryLogPolicy.shouldReport(http: failure))

    let entry = Log.makeEntry(
      level: .error,
      scope: "ApiClient",
      message: "request failed",
      error: nil,
      source: LogSourceLocation(file: "ApiClient.swift", function: "request()", line: 221),
      detail: .scrubbed
    )
    #expect(SentryLogPolicy.fingerprint(entry: entry, errorCategory: nil, http: failure) == [
      "app-error", "ApiClient.swift", "221", "none", "GET", "/v1/getMe", "500",
    ])
  }

  @Test("HTTP diagnostics omit unsafe request identifiers")
  func httpDiagnosticsDropUnsafeRequestID() throws {
    let diagnostic = try #require(HTTPLogMetadata(
      method: "GET",
      endpointTemplate: "/v1/getMe",
      statusCode: 500,
      requestID: "request id with user@example.com"
    ))

    #expect(diagnostic.requestID == nil)
    #expect(!diagnostic.consoleMessage.contains("example.com"))

    let nonServerRequestID = try #require(HTTPLogMetadata(
      method: "GET",
      endpointTemplate: "/v1/getMe",
      statusCode: 500,
      requestID: "request:123"
    ))
    #expect(nonServerRequestID.requestID == nil)

    let nonASCIIRequestID = try #require(HTTPLogMetadata(
      method: "GET",
      endpointTemplate: "/v1/getMe",
      statusCode: 500,
      requestID: "requést-123"
    ))
    #expect(nonASCIIRequestID.requestID == nil)
  }

  @Test("performance breadcrumbs drop raw messages identifiers and labels")
  func performanceBreadcrumbProjectionDropsRawContent() throws {
    let projection = PerformanceTrace.privacySafeBreadcrumbProjection(
      message: "message-token-sentinel",
      category: "Grid.Access",
      data: [
        "space_id": Int64(42),
        "reason": "person@example.com",
        "duration_ms": 125,
        "success": true,
      ]
    )

    #expect(projection.message == "performance_event")
    #expect(projection.category == "Grid.Access")
    #expect(projection.data["space_id"] == nil)
    #expect(projection.data["reason"] == nil)
    #expect(try #require(projection.data["duration_ms"] as? Double) == 125)
    #expect(try #require(projection.data["success"] as? Bool))
  }

  @Test("performance breadcrumbs bound unknown categories and metrics")
  func performanceBreadcrumbProjectionIsBounded() throws {
    let projection = PerformanceTrace.privacySafeBreadcrumbProjection(
      message: "raw-message",
      category: "user@example.com",
      data: [
        "duration_ms": Double.infinity,
        "elapsed_ms": 2_000_000_000_000.0,
        "unknown": "raw-value",
      ]
    )

    #expect(projection.category == "performance")
    #expect(projection.data["duration_ms"] == nil)
    #expect(try #require(projection.data["elapsed_ms"] as? Double) == 1_000_000_000_000)
    #expect(projection.data["unknown"] == nil)
  }

  @Test("realtime pressure breadcrumbs retain only bounded aggregate metrics")
  func realtimePressureBreadcrumbProjectionRetainsAggregateMetrics() throws {
    let projection = PerformanceTrace.privacySafeBreadcrumbProjection(
      message: "method=getGrid account=secret",
      category: "realtime.transaction",
      data: [
        "queued": 33,
        "outstanding": 32,
        "oldest_queue_age_ms": 125,
        "window_saturations": 1,
        "ephemeral_superseded": 4,
        "ephemeral_expired": 2,
        "capacity_rejections": 0,
        "method": "getGrid",
      ]
    )

    #expect(projection.message == "performance_event")
    #expect(projection.category == "realtime.transaction")
    #expect(try #require(projection.data["queued"] as? Double) == 33)
    #expect(try #require(projection.data["outstanding"] as? Double) == 32)
    #expect(try #require(projection.data["oldest_queue_age_ms"] as? Double) == 125)
    #expect(try #require(projection.data["window_saturations"] as? Double) == 1)
    #expect(try #require(projection.data["ephemeral_superseded"] as? Double) == 4)
    #expect(try #require(projection.data["ephemeral_expired"] as? Double) == 2)
    #expect(try #require(projection.data["capacity_rejections"] as? Double) == 0)
    #expect(projection.data["method"] == nil)
  }

  @Test("sync overflow breadcrumbs retain recovery metrics without bucket identity")
  func syncOverflowBreadcrumbProjectionRetainsRecoveryMetrics() throws {
    let projection = PerformanceTrace.privacySafeBreadcrumbProjection(
      message: "bucket=chat:123",
      category: "sync.realtime",
      data: [
        "buffered": 4_096,
        "buffered_bytes": 16 * 1_024 * 1_024,
        "target_seq": 7_000,
        "bucket_id": 123,
      ]
    )

    #expect(projection.message == "performance_event")
    #expect(projection.category == "sync.realtime")
    #expect(try #require(projection.data["buffered"] as? Double) == 4_096)
    #expect(try #require(projection.data["buffered_bytes"] as? Double) == 16 * 1_024 * 1_024)
    #expect(try #require(projection.data["target_seq"] as? Double) == 7_000)
    #expect(projection.data["bucket_id"] == nil)
  }

  @Test("bootstrap projection breadcrumbs retain only their finite phase and duration")
  func bootstrapProjectionBreadcrumbProjectionRetainsFinitePhase() throws {
    for category in ["sync.bootstrap.chats", "sync.bootstrap.me", "sync.bootstrap.settings"] {
      let projection = PerformanceTrace.privacySafeBreadcrumbProjection(
        message: "account=secret",
        category: category,
        data: ["duration_ms": 5_001, "user_id": 42]
      )

      #expect(projection.message == "performance_event")
      #expect(projection.category == category)
      #expect(try #require(projection.data["duration_ms"] as? Double) == 5_001)
      #expect(projection.data["user_id"] == nil)
    }
  }

  @Test("transport overflow breadcrumbs retain queue pressure without request identity")
  func transportOverflowBreadcrumbProjectionRetainsQueuePressure() throws {
    let projection = PerformanceTrace.privacySafeBreadcrumbProjection(
      message: "request=secret",
      category: "realtime.transport",
      data: [
        "pending_rpc": 12,
        "pending_probe": 1,
        "queued_write": 256,
        "queued_bytes": 16 * 1_024 * 1_024,
        "maximum_message_bytes": 16 * 1_024 * 1_024 + 4,
        "transport_generation": 3,
        "during_handshake": false,
        "inbound_message_too_large": true,
        "inbound_update_overflow": 1,
        "outbound_write_overflow": 0,
        "direct_capacity_rejections": 3,
        "request_id": 99,
      ]
    )

    #expect(projection.message == "performance_event")
    #expect(projection.category == "realtime.transport")
    #expect(try #require(projection.data["pending_rpc"] as? Double) == 12)
    #expect(try #require(projection.data["pending_probe"] as? Double) == 1)
    #expect(try #require(projection.data["queued_write"] as? Double) == 256)
    #expect(try #require(projection.data["queued_bytes"] as? Double) == 16 * 1_024 * 1_024)
    #expect(try #require(projection.data["maximum_message_bytes"] as? Double) == 16 * 1_024 * 1_024 + 4)
    #expect(try #require(projection.data["transport_generation"] as? Double) == 3)
    #expect(try #require(projection.data["during_handshake"] as? Bool) == false)
    #expect(try #require(projection.data["inbound_message_too_large"] as? Bool))
    #expect(try #require(projection.data["inbound_update_overflow"] as? Double) == 1)
    #expect(try #require(projection.data["outbound_write_overflow"] as? Double) == 0)
    #expect(try #require(projection.data["direct_capacity_rejections"] as? Double) == 3)
    #expect(projection.data["request_id"] == nil)
  }

  @Test("performance breadcrumb metric types cannot cross bridge")
  func performanceBreadcrumbProjectionRejectsCrossTypeValues() {
    let projection = PerformanceTrace.privacySafeBreadcrumbProjection(
      message: "raw-message",
      category: "Grid.Access",
      data: [
        "duration_ms": true,
        "elapsed_ms": NSNumber(value: false),
        "success": 1,
        "requested": NSNumber(value: 2),
      ]
    )

    #expect(projection.data.isEmpty)
  }

  @Test("connection breadcrumbs keep only bounded state, reason and protocol vocabulary")
  func connectionBreadcrumbProjectionKeepsBoundedVocabulary() throws {
    let projection = PerformanceTrace.privacySafeBreadcrumbProjection(
      message: "state=open host=api.example.com",
      category: "realtime.connection",
      data: [
        "state": "open",
        "reason": "person@example.com",
        "drop_reason": "network_route_changed",
        "protocol": 3,
        "session": 12,
        "down_ms": 640,
        "reconnect_ms": 410,
        "host": "api.example.com",
      ]
    )

    #expect(projection.message == "performance_event")
    #expect(projection.category == "realtime.connection")
    #expect(projection.data["state"] as? String == "open")
    #expect(projection.data["drop_reason"] as? String == "network_route_changed")
    #expect(projection.data["reason"] == nil)
    #expect(projection.data["protocol"] == nil)
    #expect(projection.data["host"] == nil)
    #expect(try #require(projection.data["session"] as? Double) == 12)
    #expect(try #require(projection.data["down_ms"] as? Double) == 640)
    #expect(try #require(projection.data["reconnect_ms"] as? Double) == 410)
    #expect(PerformanceTrace.isAllowedEnumValue("v3", for: "protocol"))
    #expect(!PerformanceTrace.isAllowedEnumValue("v4", for: "protocol"))
  }
}
