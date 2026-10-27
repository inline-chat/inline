import Foundation
@testable import InlineKit
@testable import InlineNotificationFence
@testable import Logger
import RealtimeV2
import Testing

@Suite("Download telemetry")
struct DownloadTelemetryTests {
  private func project(_ data: [String: Any], event: String = DownloadTelemetry.eventName) -> [String: Any] {
    PerformanceTrace.privacySafeBreadcrumbProjection(message: event, category: event, data: data).data
  }

  @Test("native fallback events survive the privacy projection intact")
  func nativeFallbackSurvivesProjection() throws {
    let error = RealtimeDirectRpcError.rpcError(errorCode: .rateLimit, message: "raw server text", code: 429)
    let data = DownloadTelemetry.data(
      outcome: .fallback(DownloadTelemetry.errorClass(error)), transport: .native, media: "video",
      expectedBytes: 250_000_000, durationMs: 4_200, carrier: "v3"
    )
    let projected = project(data)

    #expect(projected["download_outcome"] as? String == "fallback")
    #expect(projected["transport"] as? String == "native")
    #expect(projected["error_class"] as? String == "rpc")
    #expect(try #require(projected["error_code"] as? Double) == 429)
    #expect(projected["media"] as? String == "video")
    #expect(projected["size_bucket"] as? String == "100_500mb")
    #expect(projected["carrier"] as? String == "v3")
    #expect(try #require(projected["duration_ms"] as? Double) == 4_200)
    #expect(projected.count == data.count)
  }

  @Test("CDN photo events keep attempts, fallback origin and not-found outcomes")
  func cdnPhotoSurvivesProjection() throws {
    let data = DownloadTelemetry.data(
      outcome: .notFound, transport: .cdn, media: DownloadTelemetry.media(forDownloadID: "photo_42"),
      expectedBytes: 0, durationMs: 90, carrier: nil, attempts: 3, afterFallback: true
    )
    let projected = project(data)

    #expect(projected["download_outcome"] as? String == "not_found")
    #expect(projected["transport"] as? String == "cdn")
    #expect(projected["media"] as? String == "photo")
    #expect(try #require(projected["attempts"] as? Double) == 3)
    #expect(try #require(projected["after_fallback"] as? Bool))
    #expect(projected["carrier"] == nil)
    #expect(projected.count == data.count)
  }

  @Test("terminal outcomes carry no error class", arguments: [
    DownloadTelemetry.Outcome.success, .permission, .canceled, .notFound,
  ])
  func terminalOutcomesOmitErrorClass(outcome: DownloadTelemetry.Outcome) {
    let data = DownloadTelemetry.data(
      outcome: outcome, transport: .cdn, media: nil, expectedBytes: 0, durationMs: 10, carrier: nil
    )
    #expect(data["download_outcome"] as? String == outcome.name)
    #expect(data["size_bucket"] as? String == "unknown")
    #expect(data["error_class"] == nil)
    #expect(data["error_code"] == nil)
    #expect(data["after_fallback"] == nil)
  }

  @Test("errors map to the fixed error vocabulary")
  func errorClasses() {
    let cases: [(any Error, String, Int?)] = [
      (RealtimeDirectRpcError.notConnected, "rpc_disconnected", nil),
      (RealtimeDirectRpcError.timeout, "rpc_timeout", nil),
      (URLError(.networkConnectionLost), "network", URLError.Code.networkConnectionLost.rawValue),
      (POSIXError(.ENOSPC), "filesystem", Int(POSIXErrorCode.ENOSPC.rawValue)),
      (NativeFileDownloadError.invalidResponse, "native", nil),
      (FileDownloadValidationError.httpStatus(403), "http", 403),
      (FileDownloadValidationError.invalidHTTPResponse, "validation", nil),
      (CocoaError(.fileReadUnknown), "other", nil),
    ]
    for (error, name, code) in cases {
      #expect(DownloadTelemetry.errorClass(error) == .init(name: name, code: code))
      #expect(project(["error_class": name])["error_class"] as? String == name)
    }
  }

  @Test("download IDs map to media kinds")
  func mediaKinds() {
    #expect(DownloadTelemetry.media(forDownloadID: "doc_1") == "document")
    #expect(DownloadTelemetry.media(forDownloadID: "video_1") == "video")
    #expect(DownloadTelemetry.media(forDownloadID: "voice_1") == "voice")
    #expect(DownloadTelemetry.media(forDownloadID: "photo_1") == "photo")
    #expect(DownloadTelemetry.media(forDownloadID: "other_1") == nil)
  }

  @Test("size buckets", arguments: [
    (Int64(-1), "unknown"), (999_999, "lt_1mb"), (1_000_000, "1_10mb"), (99_999_999, "10_100mb"),
    (500_000_000, "100_500mb"), (500_000_001, "gt_500mb"),
  ])
  func sizeBuckets(bytes: Int64, bucket: String) {
    #expect(DownloadTelemetry.sizeBucket(bytes) == bucket)
  }

  @Test("extension outcome vocabulary is on the allow-list")
  func extensionVocabularyIsAllowed() {
    let rejections: [NotificationAccountAdmission.Rejection] = [
      .missingRecipient, .missingFence, .fenceUnavailable, .signedOut, .otherAccount,
    ]
    for rejection in rejections {
      #expect(PerformanceTrace.isAllowedEnumValue(rejection.rawValue, for: "withheld_reason"))
    }
    for outcome in ["decrypted", "plaintext", "unsupported_payload", "key_missing", "decrypt_failed", "withheld", "sync"] {
      #expect(PerformanceTrace.isAllowedEnumValue(outcome, for: "notification_outcome"))
    }
    for kind in [
      "video_transcode_export_preset", "share_photo_heic_as_document", "share_photo_mime_as_document",
      "create_thread_direct",
    ] {
      #expect(PerformanceTrace.isAllowedEnumValue(kind, for: "fallback_kind"))
    }
    #expect(PerformanceTrace.isAllowedEnumValue("expired", for: "delivery_end"))
  }

  @Test("extension outbox counts distinct outcomes and drains once")
  func extensionOutboxCountsAndDrains() throws {
    let suiteName = "inline.tests.extension-health.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
    let outbox = ExtensionHealthOutbox(suiteName: suiteName)

    outbox.record("notifications.delivery", ["notification_outcome": "decrypted"])
    outbox.record("notifications.delivery", ["notification_outcome": "decrypted"])
    outbox.record("notifications.delivery", ["notification_outcome": "key_missing"])

    let entries = outbox.drain()
    #expect(entries.count == 2)
    #expect(entries.first { $0.fields["notification_outcome"] == "decrypted" }?.count == 2)
    #expect(entries.first { $0.fields["notification_outcome"] == "key_missing" }?.count == 1)
    #expect(outbox.drain().isEmpty)
  }

  @Test("extension outbox stops adding new outcomes at its cap but keeps counting")
  func extensionOutboxIsBounded() {
    let suiteName = "inline.tests.extension-health.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
    let outbox = ExtensionHealthOutbox(suiteName: suiteName)

    for index in 0 ... ExtensionHealthOutbox.maxEntries {
      outbox.record("app.fallback", ["fallback_kind": "kind_\(index)"])
    }
    outbox.record("app.fallback", ["fallback_kind": "kind_0"])

    let entries = outbox.drain()
    #expect(entries.count == ExtensionHealthOutbox.maxEntries)
    #expect(entries.first { $0.fields["fallback_kind"] == "kind_0" }?.count == 2)
  }
}
