import Foundation
#if !IOS_ONBOARDING_GALLERY_APP
import InlineKit
import Logger
#endif
import SwiftUI

public class OnboardingUtils: @unchecked Sendable {
  public static var shared = OnboardingUtils()

  public var hPadding: CGFloat = 24
  public var buttonBottomPadding: CGFloat = 18

  #if !IOS_ONBOARDING_GALLERY_APP
  public func showError(
    error: any Error,
    errorMsg: Binding<String>
  ) {
    let fallback = String(localized: "Something went wrong. Please try again.")
    let message: String?

    if let apiError = error as? APIError {
      message = switch apiError {
      case .networkError:
        String(localized: "Check your connection and try again.")
      case .rateLimited, .httpError(statusCode: 420), .httpError(statusCode: 429):
        String(localized: "Too many tries. Please try again after a few minutes.")
      case .httpError(statusCode: 408):
        String(localized: "The request took too long. Please try again.")
      case let .error(_, _, description):
        description
      case .invalidURL, .invalidResponse, .httpError, .decodingError:
        fallback
      }
    } else if let urlError = error as? URLError {
      message = urlError.code == .timedOut
        ? String(localized: "The request took too long. Please try again.")
        : String(localized: "Check your connection and try again.")
    } else {
      // Native login preserves public RPC messages through LocalizedError.
      message = (error as? any LocalizedError)?.errorDescription
    }

    if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      errorMsg.wrappedValue = message
    } else {
      errorMsg.wrappedValue = fallback
    }
    Log.shared.error("Onboarding request failed", error: error)
  }

  #endif

  public init() {}
}
