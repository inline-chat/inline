import Foundation
import InlineProtocol

extension RealtimeDirectRpcError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .notAuthorized:
      String(localized: "Your session has expired. Sign in again.")
    case .notConnected:
      String(localized: "Inline is offline. Check your connection and try again.")
    case .timeout:
      String(localized: "The request took too long. Try again.")
    case let .rpcError(errorCode, message, code):
      RealtimeErrorPresentation.rpcErrorDescription(
        errorCode: errorCode,
        serverMessage: message,
        statusCode: code
      )
    case let .unknown(error):
      Self.unknownErrorDescription(error)
    }
  }

  private static func unknownErrorDescription(_ error: Error) -> String {
    if let urlError = error as? URLError {
      switch urlError.code {
      case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
        return String(localized: "Inline is offline. Check your connection and try again.")
      case .timedOut:
        return String(localized: "The request took too long. Try again.")
      default:
        break
      }
    }

    return String(localized: "Something went wrong. Try again.")
  }
}

public enum RealtimeErrorPresentation {
  public static func rpcErrorDescription(
    errorCode: InlineProtocol.RpcError.Code,
    serverMessage: String?,
    statusCode: Int
  ) -> String {
    if let serverMessage,
       !serverMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return serverMessage
    }

    return switch errorCode {
    case .badRequest:
      String(localized: "Check the request and try again.")
    case .unauthenticated:
      String(localized: "Your session has expired. Sign in again.")
    case .rateLimit:
      String(localized: "Too many requests. Wait a moment and try again.")
    case .internalError:
      String(localized: "Inline is having trouble right now. Try again.")
    case .peerIDInvalid:
      String(localized: "That chat or person is no longer available.")
    case .messageIDInvalid:
      String(localized: "That message is no longer available.")
    case .userIDInvalid:
      String(localized: "That person is no longer available.")
    case .userAlreadyMember:
      String(localized: "That person is already a member.")
    case .spaceIDInvalid:
      String(localized: "That space is no longer available.")
    case .chatIDInvalid:
      String(localized: "That chat is no longer available.")
    case .emailInvalid:
      String(localized: "Enter a valid email address.")
    case .phoneNumberInvalid:
      String(localized: "Enter a valid phone number.")
    case .spaceAdminRequired:
      String(localized: "A space admin must do that.")
    case .spaceOwnerRequired:
      String(localized: "The space owner must do that.")
    case .usernameInvalid:
      String(localized: "Enter a valid username.")
    case .usernameTaken:
      String(localized: "That username is already taken.")
    case .firstNameInvalid:
      String(localized: "Enter a valid first name.")
    case .urlPreviewUnavailable:
      String(localized: "This link can’t be previewed.")
    case .unknown, .UNRECOGNIZED:
      statusFallback(statusCode)
    }
  }

  private static func statusFallback(_ statusCode: Int) -> String {
    switch statusCode {
    case 401:
      String(localized: "Your session has expired. Sign in again.")
    case 403:
      String(localized: "You don’t have permission to do that.")
    case 404:
      String(localized: "That item is no longer available.")
    case 408:
      String(localized: "The request took too long. Try again.")
    case 420, 429:
      String(localized: "Too many requests. Wait a moment and try again.")
    case 500...599:
      String(localized: "Inline is having trouble right now. Try again.")
    default:
      String(localized: "Inline couldn’t complete that request.")
    }
  }
}
