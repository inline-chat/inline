import Foundation
import GRDB
import InlineKit
import Logger
import RealtimeV2
import Sentry

enum ExperimentalHomeLoadStage: String, Sendable {
  case localInitialRead = "local_initial_read"
  case localObservation = "local_observation"
  case getMe = "get_me"
  case getChats = "get_chats"
  case getSpaces = "get_spaces"
  case getDialogs = "get_dialogs"

  var source: String {
    switch self {
    case .localInitialRead, .localObservation:
      "local_database"
    case .getMe, .getChats, .getSpaces, .getDialogs:
      "remote_refresh"
    }
  }
}

enum ExperimentalHomeLoadSurface: String, Sendable {
  case home
  case space
}

struct ExperimentalHomeLoadDiagnosticContext: Sendable {
  let surface: ExperimentalHomeLoadSurface
  let cachedChatCount: Int
  let authAvailable: Bool?
  let realtimeState: RealtimeConnectionState?
}

/// Keeps home-load diagnostics queryable without sending chat, space, user, or error text.
/// Debug builds still retain the full local error through Logger; release Sentry events only
/// contain the bounded stage, error type/category, booleans, and counts below.
@MainActor
enum ExperimentalHomeLoadDiagnostics {
  private static let sentryFailureEvent = "ios_home_load_failure"
  private static let log = Log.scoped("IOSHomeLoad")
  private static var lastDialogCapture: [String: Date] = [:]

  static func reportFailure(
    stage: ExperimentalHomeLoadStage,
    error: any Error,
    taskIsCancelled: Bool,
    context: ExperimentalHomeLoadDiagnosticContext
  ) {
    guard !taskIsCancelled else {
      log.debug(
        "event=ios.home.load_cancelled stage=\(stage.rawValue) source=\(stage.source)"
      )
      return
    }

    let category = errorCategory(error)
    let errorType = safeErrorType(error)
    let localMessage = diagnosticMessage(
      event: "ios.home.load_failed",
      stage: stage,
      category: category,
      errorType: errorType,
      context: context
    )

    // Avoid a duplicate generic Sentry event when the structured event below is active.
    // In debug, where Sentry is intentionally disabled, retain the complete local error.
    if SentrySDK.isEnabled {
      log.warning("\(localMessage) error=\(String(describing: error))")
    } else {
      log.error(localMessage, error: error)
    }

    captureFailure(
      stage: stage,
      category: category,
      errorType: errorType,
      context: context
    )
  }

  private static func captureFailure(
    stage: ExperimentalHomeLoadStage,
    category: String,
    errorType: String,
    context: ExperimentalHomeLoadDiagnosticContext
  ) {
    guard SentrySDK.isEnabled else { return }

    // A single failed direct refresh can fan out across every cached space. Keep one
    // representative dialogs event per category/surface in a short window.
    if stage == .getDialogs {
      let key = "\(category)|\(context.surface.rawValue)"
      let now = Date()
      if let lastCapture = lastDialogCapture[key], now.timeIntervalSince(lastCapture) < 30 {
        return
      }
      lastDialogCapture[key] = now
    }

    _ = SentrySDK.capture(message: sentryFailureEvent) { scope in
      scope.setLevel(.error)
      scope.setFingerprint(["ios-home-load", sentryFailureEvent, stage.rawValue, category])
      scope.setTag(value: sentryFailureEvent, key: "event")
      scope.setTag(value: stage.rawValue, key: "home_load.stage")
      scope.setTag(value: stage.source, key: "home_load.source")
      scope.setTag(value: context.surface.rawValue, key: "home_load.surface")
      scope.setTag(value: category, key: "home_load.error_category")
      scope.setTag(value: errorType, key: "home_load.error_type")
      scope.setTag(
        value: context.cachedChatCount == 0 ? "empty" : "populated",
        key: "home_load.cache"
      )
      scope.setTag(value: booleanLabel(context.authAvailable), key: "home_load.auth_available")
      scope.setTag(
        value: realtimeStateLabel(context.realtimeState),
        key: "home_load.realtime_state"
      )
      scope.setExtra(value: max(0, context.cachedChatCount), key: "home_load.cached_chat_count")
    }
  }

  private static func diagnosticMessage(
    event: String,
    stage: ExperimentalHomeLoadStage,
    category: String,
    errorType: String,
    context: ExperimentalHomeLoadDiagnosticContext
  ) -> String {
    [
      "event=\(event)",
      "stage=\(stage.rawValue)",
      "source=\(stage.source)",
      "surface=\(context.surface.rawValue)",
      "error_category=\(category)",
      "error_type=\(errorType)",
      "task_cancelled=false",
      "auth_available=\(booleanLabel(context.authAvailable))",
      "realtime_state=\(realtimeStateLabel(context.realtimeState))",
      "cached_chat_count=\(max(0, context.cachedChatCount))",
    ].joined(separator: " ")
  }

  private static func errorCategory(_ error: any Error) -> String {
    if error is CancellationError {
      return "unexpected_cancellation"
    }
    if let databaseError = error as? DatabaseError {
      return "database_\(databaseError.extendedResultCode.rawValue)"
    }
    if let urlError = error as? URLError {
      return "url_\(urlError.errorCode)"
    }
    if let apiError = error as? APIError {
      switch apiError {
      case .invalidURL:
        return "api_invalid_url"
      case .invalidResponse:
        return "api_invalid_response"
      case .httpError(let statusCode):
        return "api_http_\(statusCode)"
      case .decodingError(let underlying):
        return "api_decoding_\(safeErrorType(underlying))"
      case .networkError:
        return "api_network"
      case .rateLimited:
        return "api_rate_limited"
      case .error(_, let errorCode, _):
        return errorCode.map { "api_server_\($0)" } ?? "api_server"
      }
    }
    if let transactionError = error as? TransactionError {
      switch transactionError {
      case .rpcError(let rpcError):
        return "transaction_rpc_\(rpcError.errorCode.rawValue)"
      case .timeout:
        return "transaction_timeout"
      case .invalid:
        return "transaction_invalid"
      case .persistenceFailed:
        return "transaction_persistence_failed"
      case .commitOutcomeUnknownAfterReconnect:
        return "transaction_commit_unknown"
      case .rejectedBeforeExecution:
        return "transaction_rejected_before_execution"
      case .dependencyFailed:
        return "transaction_dependency_failed"
      }
    }
    if let directError = error as? RealtimeDirectRpcError {
      switch directError {
      case .notAuthorized:
        return "direct_rpc_not_authorized"
      case .notConnected:
        return "direct_rpc_not_connected"
      case .timeout:
        return "direct_rpc_timeout"
      case .commitOutcomeUnknown:
        return "direct_rpc_commit_unknown"
      case .capacityExceeded:
        return "direct_rpc_capacity_exceeded"
      case .rpcError(let errorCode, _, let code):
        return "direct_rpc_\(errorCode.rawValue)_\(code)"
      case .unknown(let underlying):
        return "direct_rpc_unknown_\(safeErrorType(underlying))_\((underlying as NSError).code)"
      }
    }

    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain {
      return "cocoa_\(nsError.code)"
    }
    return "other"
  }

  private static func safeErrorType(_ error: any Error) -> String {
    let raw = String(reflecting: type(of: error))
    let safeScalars = raw.unicodeScalars.map { scalar -> Character in
      if CharacterSet.alphanumerics.contains(scalar) || "._".unicodeScalars.contains(scalar) {
        return Character(String(scalar))
      }
      return "_"
    }
    return String(safeScalars.prefix(80))
  }

  private static func booleanLabel(_ value: Bool?) -> String {
    switch value {
    case true: "true"
    case false: "false"
    case nil: "unknown"
    }
  }

  private static func realtimeStateLabel(_ state: RealtimeConnectionState?) -> String {
    switch state {
    case .connecting: "connecting"
    case .updating: "updating"
    case .connected: "connected"
    case nil: "unknown"
    }
  }
}
