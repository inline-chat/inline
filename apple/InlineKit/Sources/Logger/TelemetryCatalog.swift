import Foundation

/// A closed catalog makes remotely exported event names and field schemas reviewable.
/// UI copy, user content, credentials, and paths belong in `TelemetryPrivateValue` only.
public enum TelemetryEvent: String, CaseIterable, Sendable {
  case httpRequestFailed = "http_request_failed"
  case realtimeTransportDisconnected = "realtime_transport_disconnected"
  case notificationProcessingFailed = "notification_processing_failed"
  case performanceThresholdExceeded = "performance_threshold_exceeded"
  case accountGenerationRejected = "account_generation_rejected"
  case subprocessFailed = "subprocess_failed"

  public var level: LogLevel {
    switch self {
    case .performanceThresholdExceeded:
      .warning
    case .httpRequestFailed,
         .realtimeTransportDisconnected,
         .notificationProcessingFailed,
         .accountGenerationRejected,
         .subprocessFailed:
      .error
    }
  }

  fileprivate var allowedFieldKeys: Set<TelemetryFieldKey> {
    switch self {
    case .httpRequestFailed:
      [.method, .endpoint, .statusCode, .requestID, .responseBytes, .privateDetail]
    case .realtimeTransportDisconnected:
      [.origin, .closeCode, .statusCode, .retryAttempt, .privateDetail]
    case .notificationProcessingFailed:
      [.operation, .privateDetail]
    case .performanceThresholdExceeded:
      [.operation, .durationMilliseconds, .thresholdMilliseconds, .privateDetail]
    case .accountGenerationRejected:
      [.operation, .generation, .privateDetail]
    case .subprocessFailed:
      [.operation, .exitStatus, .timedOut, .outputTruncated, .privateDetail]
    }
  }
}

public enum TelemetryHTTPMethod: String, Sendable {
  case get = "GET"
  case post = "POST"
  case put = "PUT"
  case patch = "PATCH"
  case delete = "DELETE"
  case other = "OTHER"
}

/// A runtime value explicitly reviewed as a low-cardinality diagnostic identifier.
/// Export sanitization remains defense in depth.
public struct TelemetryIdentifier: Sendable, Equatable, CustomStringConvertible {
  let localValue: String

  public init(_ value: String) {
    localValue = value
  }

  public var description: String {
    "<diagnostic-identifier>"
  }
}

/// A value that may be useful locally but must never be exported or printable by accident.
public struct TelemetryPrivateValue: Sendable, Equatable, CustomStringConvertible {
  let localValue: String

  public init(_ value: String) {
    localValue = value
  }

  public var description: String {
    "<private>"
  }
}

public enum TelemetryField: Sendable, Equatable {
  case method(TelemetryHTTPMethod)
  case endpoint(TelemetryIdentifier)
  case statusCode(Int)
  case requestID(TelemetryIdentifier)
  case responseBytes(Int)
  case origin(TelemetryIdentifier)
  case closeCode(Int)
  case retryAttempt(Int)
  case operation(TelemetryIdentifier)
  case durationMilliseconds(Int)
  case thresholdMilliseconds(Int)
  case generation(UInt64)
  case exitStatus(Int32)
  case timedOut(Bool)
  case outputTruncated(Bool)
  case privateDetail(TelemetryPrivateValue)

  fileprivate var key: TelemetryFieldKey {
    switch self {
    case .method: .method
    case .endpoint: .endpoint
    case .statusCode: .statusCode
    case .requestID: .requestID
    case .responseBytes: .responseBytes
    case .origin: .origin
    case .closeCode: .closeCode
    case .retryAttempt: .retryAttempt
    case .operation: .operation
    case .durationMilliseconds: .durationMilliseconds
    case .thresholdMilliseconds: .thresholdMilliseconds
    case .generation: .generation
    case .exitStatus: .exitStatus
    case .timedOut: .timedOut
    case .outputTruncated: .outputTruncated
    case .privateDetail: .privateDetail
    }
  }

  fileprivate var logField: LogField {
    switch self {
    case let .method(value):
      .diagnosticIdentifier("method", value.rawValue)
    case let .endpoint(value):
      .diagnosticIdentifier("endpoint", value.localValue)
    case let .statusCode(value):
      .diagnostic("status_code", value)
    case let .requestID(value):
      .diagnosticIdentifier("request_id", value.localValue)
    case let .responseBytes(value):
      .diagnostic("response_bytes", value)
    case let .origin(value):
      .diagnosticIdentifier("origin", value.localValue)
    case let .closeCode(value):
      .diagnostic("close_code", value)
    case let .retryAttempt(value):
      .diagnostic("retry_attempt", value)
    case let .operation(value):
      .diagnosticIdentifier("operation", value.localValue)
    case let .durationMilliseconds(value):
      .diagnostic("duration_ms", value)
    case let .thresholdMilliseconds(value):
      .diagnostic("threshold_ms", value)
    case let .generation(value):
      .diagnosticIdentifier("generation", String(value))
    case let .exitStatus(value):
      .diagnostic("exit_status", Int(value))
    case let .timedOut(value):
      .diagnostic("timed_out", value)
    case let .outputTruncated(value):
      .diagnostic("output_truncated", value)
    case let .privateDetail(value):
      .sensitive("private_detail", value.localValue)
    }
  }
}

public enum TelemetryCatalogError: Error, Equatable, Sendable {
  case unsupportedField(event: TelemetryEvent, field: String)
  case duplicateField(event: TelemetryEvent, field: String)
}

public struct TelemetryRecord: Sendable, Equatable {
  public let event: TelemetryEvent
  public let fields: [TelemetryField]

  public init(event: TelemetryEvent, fields: [TelemetryField]) throws {
    var seen = Set<TelemetryFieldKey>()
    for field in fields {
      let key = field.key
      guard event.allowedFieldKeys.contains(key) else {
        throw TelemetryCatalogError.unsupportedField(event: event, field: key.rawValue)
      }
      guard seen.insert(key).inserted else {
        throw TelemetryCatalogError.duplicateField(event: event, field: key.rawValue)
      }
    }
    self.event = event
    self.fields = fields
  }

  var logFields: [LogField] {
    fields.map(\.logField)
  }
}

private enum TelemetryFieldKey: String, Sendable {
  case method
  case endpoint
  case statusCode = "status_code"
  case requestID = "request_id"
  case responseBytes = "response_bytes"
  case origin
  case closeCode = "close_code"
  case retryAttempt = "retry_attempt"
  case operation
  case durationMilliseconds = "duration_ms"
  case thresholdMilliseconds = "threshold_ms"
  case generation
  case exitStatus = "exit_status"
  case timedOut = "timed_out"
  case outputTruncated = "output_truncated"
  case privateDetail = "private_detail"
}
