import Foundation
import Logger
import RealtimeV2

/// One aggregatable health event per finished file download, native or CDN, so the two can be
/// compared before native becomes the default. Fixed vocabulary only: no file, message, chat or
/// account identifiers, and no byte counts finer than the size bucket.
enum DownloadTelemetry {
  static let eventName = "files.download"

  enum Transport: String {
    case native
    case cdn
  }

  struct ErrorClass: Equatable {
    let name: String
    let code: Int?
  }

  enum Outcome: Equatable {
    case success
    /// Native failed and the CDN took over.
    case fallback(ErrorClass)
    /// Terminal by design: permission failures never fall back.
    case permission
    case canceled
    /// Failed with no further transport to try.
    case failed(ErrorClass)
    case notFound

    var name: String {
      switch self {
      case .success: "success"
      case .fallback: "fallback"
      case .permission: "permission"
      case .canceled: "canceled"
      case .failed: "failed"
      case .notFound: "not_found"
      }
    }

    var errorClass: ErrorClass? {
      switch self {
      case let .fallback(errorClass), let .failed(errorClass): errorClass
      case .success, .permission, .canceled, .notFound: nil
      }
    }
  }

  static func record(
    _ outcome: Outcome,
    transport: Transport,
    downloadID: String,
    expectedBytes: Int64,
    startedAt: Date,
    attempts: Int? = nil,
    afterFallback: Bool = false
  ) {
    PerformanceTrace.healthEvent(eventName, data: data(
      outcome: outcome,
      transport: transport,
      media: media(forDownloadID: downloadID),
      expectedBytes: expectedBytes,
      durationMs: PerformanceTrace.elapsedMilliseconds(since: startedAt),
      carrier: transport == .native ? RealtimeTelemetryContext.protocolName : nil,
      attempts: attempts,
      afterFallback: afterFallback
    ))
  }

  static func data(
    outcome: Outcome,
    transport: Transport,
    media: String?,
    expectedBytes: Int64,
    durationMs: Int,
    carrier: String?,
    attempts: Int? = nil,
    afterFallback: Bool = false
  ) -> [String: Any] {
    var data: [String: Any] = [
      "download_outcome": outcome.name,
      "transport": transport.rawValue,
      "size_bucket": sizeBucket(expectedBytes),
      "duration_ms": durationMs,
    ]
    if let errorClass = outcome.errorClass {
      data["error_class"] = errorClass.name
      if let code = errorClass.code { data["error_code"] = code }
    }
    if let media { data["media"] = media }
    if let carrier { data["carrier"] = carrier }
    if let attempts { data["attempts"] = attempts }
    if afterFallback { data["after_fallback"] = true }
    return data
  }

  static func media(forDownloadID id: String) -> String? {
    if id.hasPrefix("doc_") { return "document" }
    if id.hasPrefix("video_") { return "video" }
    if id.hasPrefix("voice_") { return "voice" }
    if id.hasPrefix("photo_") { return "photo" }
    return nil
  }

  static func errorClass(_ error: any Error) -> ErrorClass {
    if let rpc = error as? RealtimeDirectRpcError {
      switch rpc {
      case let .rpcError(_, _, status): return ErrorClass(name: "rpc", code: status)
      case .notConnected: return ErrorClass(name: "rpc_disconnected", code: nil)
      case .timeout: return ErrorClass(name: "rpc_timeout", code: nil)
      case .commitOutcomeUnknown: return ErrorClass(name: "rpc_outcome_unknown", code: nil)
      case .capacityExceeded: return ErrorClass(name: "rpc_capacity", code: nil)
      case .notAuthorized: return ErrorClass(name: "rpc_unauthorized", code: nil)
      case .unknown: return ErrorClass(name: "rpc_unknown", code: nil)
      }
    }
    if let network = error as? URLError { return ErrorClass(name: "network", code: network.code.rawValue) }
    if let filesystem = error as? POSIXError { return ErrorClass(name: "filesystem", code: Int(filesystem.code.rawValue)) }
    if error is NativeFileDownloadError { return ErrorClass(name: "native", code: nil) }
    if case let .httpStatus(status)? = error as? FileDownloadValidationError {
      return ErrorClass(name: "http", code: status)
    }
    if error is FileDownloadValidationError { return ErrorClass(name: "validation", code: nil) }
    return ErrorClass(name: "other", code: nil)
  }

  static func sizeBucket(_ bytes: Int64) -> String {
    switch bytes {
    case ...0: "unknown"
    case ..<1_000_000: "lt_1mb"
    case ..<10_000_000: "1_10mb"
    case ..<100_000_000: "10_100mb"
    case ...500_000_000: "100_500mb"
    default: "gt_500mb"
    }
  }
}
