import Foundation
import Testing

@testable import Logger

@Suite("Closed telemetry catalog", .serialized)
struct TelemetryCatalogTests {
  @Test("every catalog event has a stable safe name and severity")
  func catalogIsClosedAndStable() {
    #expect(TelemetryEvent.allCases.count == 6)
    for event in TelemetryEvent.allCases {
      #expect(!event.rawValue.isEmpty)
      #expect(event.rawValue.allSatisfy { $0.isLowercase || $0 == "_" })
      #expect(event.level == .error || event.level == .warning)
    }
  }

  @Test("typed HTTP diagnostics export while private detail stays local")
  func typedHTTPEvent() throws {
    let sink = TelemetryRecordingSink()
    Log.addSink(sink, id: "telemetry-catalog-tests")
    defer { Log.removeSink(id: "telemetry-catalog-tests") }

    let secret = "sentinel body with code 914207"
    Log.scoped("ApiClient").telemetry(
      .httpRequestFailed,
      fields: [
        .method(.post),
        .endpoint(TelemetryIdentifier("verifyEmailCode")),
        .statusCode(401),
        .requestID(TelemetryIdentifier("req_safe_01")),
        .responseBytes(123),
        .privateDetail(TelemetryPrivateValue(secret)),
      ]
    )

    let event = try #require(sink.events.last)
    #expect(event.eventName == "http_request_failed")
    #expect(event.exportedMessage.contains("method=POST"))
    #expect(event.exportedMessage.contains("endpoint=verifyEmailCode"))
    #expect(event.exportedMessage.contains("status_code=401"))
    #expect(!event.exportedMessage.contains(secret))
    #expect(event.entry.message.contains(secret))
  }

  @Test("catalog rejects unsupported and duplicate fields")
  func schemaValidation() {
    #expect(throws: TelemetryCatalogError.self) {
      _ = try TelemetryRecord(
        event: .httpRequestFailed,
        fields: [.durationMilliseconds(100)]
      )
    }
    #expect(throws: TelemetryCatalogError.self) {
      _ = try TelemetryRecord(
        event: .httpRequestFailed,
        fields: [.statusCode(500), .statusCode(503)]
      )
    }
  }

  @Test("runtime schema violations never export rejected values")
  func schemaViolationIsMetadataOnly() throws {
    let sink = TelemetryRecordingSink()
    Log.addSink(sink, id: "telemetry-catalog-tests")
    defer { Log.removeSink(id: "telemetry-catalog-tests") }

    Log.scoped("Boundary").telemetry(
      .notificationProcessingFailed,
      fields: [.endpoint(TelemetryIdentifier("sentinel@example.invalid"))]
    )

    let event = try #require(sink.events.last)
    #expect(event.eventName == "telemetry_schema_violation")
    #expect(event.exportedMessage.contains("rejected_event=notification_processing_failed"))
    #expect(!event.exportedMessage.contains("sentinel"))
    #expect(!event.entry.message.contains("sentinel"))
  }

  @Test("private and diagnostic wrappers do not print their values")
  func wrappersAreNonPrintable() {
    #expect(String(describing: TelemetryPrivateValue("sentinel-secret")) == "<private>")
    #expect(String(describing: TelemetryIdentifier("sentinel-identifier")) == "<diagnostic-identifier>")
  }

  @Test("unknown HTTP methods are represented without being mislabeled")
  func unknownHTTPMethod() {
    #expect(TelemetryHTTPMethod(rawValue: "PROPFIND") == nil)
    #expect(TelemetryHTTPMethod.other.rawValue == "OTHER")
  }
}

private final class TelemetryRecordingSink: LogSink, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [LogEvent] = []

  var events: [LogEvent] {
    lock.withLock { storage }
  }

  func write(_ event: LogEvent) {
    lock.withLock { storage.append(event) }
  }
}
