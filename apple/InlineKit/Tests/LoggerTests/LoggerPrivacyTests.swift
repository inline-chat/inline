import Foundation
import Testing

@testable import Logger

@Suite("Logger privacy boundary", .serialized)
struct LoggerPrivacyTests {
  @Test("warning uses default OSLog severity rather than fault")
  func warningIsNotAFault() {
    #expect(LogLevel.warning.osLogType == .default)
  }

  @Test("legacy interpolated text is local-only")
  func legacyInterpolatedTextIsNotExported() throws {
    let sink = RecordingLogSink()
    Log.addSink(sink, id: "logger-privacy-tests")
    defer { Log.removeSink(id: "logger-privacy-tests") }

    let otp = "914207"
    let email = "sentinel-user@example.invalid"
    let challenge = "challenge-sentinel-63a8"
    let invite = "invite-sentinel-f215"
    let body = "user wrote sentinel-message-dc04"
    let filePath = "/Users/sentinel/private/transcript.txt"
    let error = NSError(
      domain: "PrivacyBoundaryTests",
      code: 401,
      userInfo: [NSLocalizedDescriptionKey: "\(body) at \(filePath)"]
    )

    Log.scoped("sentinel-user@example.invalid").error(
      "verify failed email=\(email) code=\(otp) challengeToken=\(challenge) inviteCode=\(invite)",
      error: error
    )

    let event = try #require(sink.events.last)
    #expect(event.entry.message.contains(email))
    #expect(event.exportedScope == "unknown")
    #expect(event.exportedMessage.contains("event=unstructured_log"))
    for secret in [otp, email, challenge, invite, body, filePath] {
      #expect(!event.exportedMessage.contains(secret))
    }
    let exportedError = try #require(event.exportedError)
    #expect(exportedError.domain == "PrivacyBoundaryTests")
    #expect(exportedError.code == 401)
    #expect(!String(describing: exportedError).contains(body))
    #expect(!String(describing: exportedError).contains(filePath))
  }

  @Test("structured events export safe diagnostics and omit sensitive fields")
  func structuredFieldsRespectPrivacy() throws {
    let sink = RecordingLogSink()
    Log.addSink(sink, id: "logger-privacy-tests")
    defer { Log.removeSink(id: "logger-privacy-tests") }

    let url = "https://api.inline.chat/v1/verifyEmailCode?email=sentinel@example.invalid&code=924613"
    let responseBody = #"{"message":"sentinel user text","challengeToken":"challenge-secret"}"#
    Log.scoped("ApiClient").error(
      event: "http_request_failed",
      fields: [
        .diagnostic("method", "GET"),
        .diagnostic("endpoint", "verifyEmailCode"),
        .diagnostic("status_code", 401),
        .diagnostic("request_id", "req_01safe"),
        .diagnostic("response_bytes", responseBody.utf8.count),
        .sensitive("url", url),
        .sensitive("response_body", responseBody),
        .sensitive("user_text", "sentinel user text"),
      ]
    )

    let event = try #require(sink.events.last)
    #expect(event.isStructured)
    #expect(event.exportedMessage.contains("event=http_request_failed"))
    #expect(event.exportedMessage.contains("method=GET"))
    #expect(event.exportedMessage.contains("status_code=401"))
    #expect(event.exportedMessage.contains("request_id=req_01safe"))
    #expect(!event.exportedMessage.contains("sentinel"))
    #expect(!event.exportedMessage.contains("challenge-secret"))
    #expect(!event.exportedMessage.contains("924613"))
    #expect(!event.exportedMessage.contains("example.invalid"))
  }

  @Test("export defense strips query values, emails, and paths from mislabeled diagnostics")
  func exportDefenseRedactsCommonSensitiveShapes() throws {
    let sink = RecordingLogSink()
    Log.addSink(sink, id: "logger-privacy-tests")
    defer { Log.removeSink(id: "logger-privacy-tests") }

    Log.scoped("Boundary").info(
      event: "redaction_probe",
      fields: [
        .diagnostic("destination", "https://example.invalid/path?token=sentinel-token&email=sentinel@example.invalid"),
        .diagnostic("contact", "sentinel@example.invalid"),
        .diagnostic("location", "/Users/sentinel/private/file.txt"),
        .diagnostic("body", "sentinel body"),
        .diagnostic("code", "381204"),
      ]
    )

    let event = try #require(sink.events.last)
    #expect(event.exportedMessage.contains("destination=https://example.invalid/path"))
    #expect(event.exportedMessage.contains("contact=redacted_email"))
    #expect(event.exportedMessage.contains("location=redacted_path"))
    #expect(!event.exportedMessage.contains("sentinel-token"))
    #expect(!event.exportedMessage.contains("sentinel@example.invalid"))
    #expect(!event.exportedMessage.contains("sentinel body"))
    #expect(!event.exportedMessage.contains("381204"))
  }

  @Test("URL redaction removes user info, query values, and fragments")
  func redactedURLPreservesOnlyRouteDiagnostics() {
    let redacted = LogPrivacy.redactedURL(
      "https://sentinel-user:sentinel-pass@example.invalid/path?token=sentinel-token#sentinel-fragment"
    )

    #expect(redacted == "https://example.invalid/path")
    #expect(!redacted.contains("sentinel"))
  }
}

private final class RecordingLogSink: LogSink, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [LogEvent] = []

  var events: [LogEvent] {
    lock.withLock { storage }
  }

  func write(_ event: LogEvent) {
    lock.withLock {
      storage.append(event)
    }
  }
}
