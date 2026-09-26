import Foundation
import Logger

/// Fixed labels only. Never include a server error message, URL, or bucket ID.
enum SyncRequestFailureReason: String, Sendable {
  case notConnected = "not_connected"
  case timeout
  case rateLimited = "rate_limited"
  case serverRejected = "server_rejected"
  case unauthorized
  case stopped
  case capacityExceeded = "capacity_exceeded"
  case outcomeUnknown = "outcome_unknown"
  case networkUnavailable = "network_unavailable"
  case transport
  case other

  init(_ error: Error) {
    if let sessionError = error as? ProtocolSessionError {
      switch sessionError {
        case .notConnected: self = .notConnected
        case .timeout: self = .timeout
        case .rpcError(let code, _, let status):
          self = code == .rateLimit || status == 429 ? .rateLimited : .serverRejected
        case .notAuthorized: self = .unauthorized
        case .stopped: self = .stopped
        case .capacityExceeded: self = .capacityExceeded
        case .commitOutcomeUnknown: self = .outcomeUnknown
      }
    } else if let urlError = error as? URLError {
      switch urlError.code {
        case .timedOut: self = .timeout
        case .notConnectedToInternet, .networkConnectionLost: self = .networkUnavailable
        default: self = .transport
      }
    } else {
      self = .other
    }
  }
}

struct SyncStateRequestFailure: Error, PrivacySafeErrorCategoryProviding {
  let reason: SyncRequestFailureReason

  var privacySafeErrorCategory: String {
    "sync_state:request_failed:\(reason.rawValue)"
  }
}

/// Only locally classified, payload-free failure categories may enter this value.
struct SyncRecoveryFailure: Error, PrivacySafeErrorCategoryProviding {
  let bucketKind: String
  let phase: String

  var privacySafeErrorCategory: String {
    "sync_recovery:\(bucketKind):\(phase)"
  }
}
