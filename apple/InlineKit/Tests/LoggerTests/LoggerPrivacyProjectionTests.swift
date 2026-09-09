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

  @Test("release projection contains only fixed metadata")
  func releaseProjectionRedactsRuntimeContent() throws {
    let entry = Log.makeEntry(
      level: .error,
      scope: "scope/user@example.com",
      message: "message-token-sentinel",
      error: SentinelError(),
      source: LogSourceLocation(
        file: "/private/user-path-sentinel/Feature.swift",
        function: "performRequest()",
        line: 42
      ),
      includeSensitiveDetails: false
    )
    let encoded = try JSONEncoder().encode(entry)
    let text = try #require(String(data: encoded, encoding: .utf8))

    for sentinel in [
      "scope/user@example.com",
      "message-token-sentinel",
      "localized-error-sentinel",
      "user-path-sentinel",
      "/private/",
    ] {
      #expect(!text.contains(sentinel))
    }
    #expect(entry.scope == "app")
    #expect(entry.file == "Feature.swift")
    #expect(entry.fileName == "Feature.swift")
    #expect(entry.line == 42)
    #expect(entry.error == "other")
  }

  @Test("release projection retains only bounded static scopes")
  func releaseProjectionSanitizesScope() {
    for scope in ["ApiClient", "FullChat", "realtime.v2", "file_upload"] {
      let entry = Log.makeEntry(
        level: .error,
        scope: scope,
        message: "request failed",
        error: nil,
        source: LogSourceLocation(file: "Feature.swift", function: "work()", line: 1),
        includeSensitiveDetails: false
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
        includeSensitiveDetails: false
      )
      #expect(entry.scope == "app")
    }
  }

  @Test("release projection retains finite URL error grouping")
  func releaseProjectionGroupsURLErrors() {
    let entry = Log.makeEntry(
      level: .error,
      scope: "network",
      message: "request failed",
      error: URLError(.timedOut),
      source: LogSourceLocation(file: "ApiClient.swift", function: "request()", line: 12),
      includeSensitiveDetails: false
    )

    #expect(entry.error == "url:\(URLError(.timedOut).errorCode)")
  }

  @Test("release projection retains only explicit bounded error categories")
  func releaseProjectionRetainsExplicitErrorCategories() {
    let source = LogSourceLocation(file: "Upload.swift", function: "upload()", line: 17)
    let categorized = Log.makeEntry(
      level: .error,
      scope: "NativeUpload",
      message: "runtime-message-sentinel",
      error: CategorizedError(privacySafeErrorCategory: "realtime_rpc:application:2:401"),
      source: source,
      includeSensitiveDetails: false
    )
    #expect(categorized.error == "realtime_rpc:application:2:401")

    let unsafe = Log.makeEntry(
      level: .error,
      scope: "NativeUpload",
      message: "runtime-message-sentinel",
      error: CategorizedError(privacySafeErrorCategory: "person@example.com"),
      source: source,
      includeSensitiveDetails: false
    )
    #expect(unsafe.error == "other")

    let unbounded = Log.makeEntry(
      level: .error,
      scope: "NativeUpload",
      message: "runtime-message-sentinel",
      error: CategorizedError(privacySafeErrorCategory: String(repeating: "a", count: 97)),
      source: source,
      includeSensitiveDetails: false
    )
    #expect(unbounded.error == "other")
  }

  @Test("debug projection retains local diagnostics")
  func debugProjectionRetainsDetails() {
    let entry = Log.makeEntry(
      level: .info,
      scope: "local-scope",
      message: "local-message",
      error: nil,
      source: LogSourceLocation(file: "/tmp/Feature.swift", function: "work()", line: 9),
      includeSensitiveDetails: true
    )

    #expect(entry.scope == "local-scope")
    #expect(entry.message.contains("local-message"))
    #expect(entry.file == "/tmp/Feature.swift")
  }

  @Test("build flavor chooses the matching log projection")
  func buildFlavorChoosesProjection() {
    #expect(Log.includeSensitiveDetails(isDebugBuild: true))
    #expect(!Log.includeSensitiveDetails(isDebugBuild: false))
    #if DEBUG || DEBUG_BUILD
    #expect(Log.includeSensitiveDetails)
    #else
    #expect(!Log.includeSensitiveDetails)
    #endif
  }

  @Test("debug console exposes the already-detailed local projection")
  func debugConsoleExposesDetails() {
    #expect(ConsoleLogSink.detailVisibility(isDebugBuild: true) == .publicDetails)
    #expect(ConsoleLogSink.detailVisibility(isDebugBuild: false) == .privateDetails)
    #if DEBUG || DEBUG_BUILD
    #expect(ConsoleLogSink.detailVisibility == .publicDetails)
    #else
    #expect(ConsoleLogSink.detailVisibility == .privateDetails)
    #endif
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
      includeSensitiveDetails: false
    )
    #expect(SentryLogPolicy.fingerprint(entry: entry, http: failure) == [
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
}
