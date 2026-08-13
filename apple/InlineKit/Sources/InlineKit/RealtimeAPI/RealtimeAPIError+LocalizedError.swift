import Foundation
import RealtimeV2

extension RealtimeAPIError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .rpcError(errorCode, message, code):
      RealtimeErrorPresentation.rpcErrorDescription(
        errorCode: errorCode,
        serverMessage: message,
        statusCode: code
      )
    case .notAuthorized:
      String(localized: "Your session has expired. Sign in again.")
    case .notConnected:
      String(localized: "Inline is offline. Check your connection and try again.")
    case .stopped:
      String(localized: "Inline is reconnecting. Try again in a moment.")
    case .unknown:
      String(localized: "Something went wrong. Try again.")
    }
  }
}
