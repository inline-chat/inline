import Foundation
import InlineKit
import Logger
import SwiftUI

public class OnboardingUtils: @unchecked Sendable {
  public static var shared = OnboardingUtils()

  public var hPadding: CGFloat = 50
  public var buttonBottomPadding: CGFloat = 18

  public func showError(
    error: APIError,
    errorMsg: Binding<String>,
    isEmail: Bool = false,
    isPhoneNumber: Bool = false
  ) {
    switch error {
      case .invalidURL:
        Log.shared.error("Failed invalidURL", error: error)
      case .invalidResponse:
        errorMsg.wrappedValue =
          "Your \(isPhoneNumber ? "phone number" : isEmail ? "email" : "code") is incorrect. Please try again."
        Log.shared.error("Failed invalidResponse", error: error)
      case let .httpError(statusCode):
        if statusCode == 500 {
          errorMsg.wrappedValue =
            "Your \(isPhoneNumber ? "phone number" : isEmail ? "email" : "code") is incorrect. Please try again."
          Log.shared.error("Failed httpError \(statusCode)", error: error)

        } else {
          Log.shared.error("Failed httpError \(statusCode)", error: error)
        }
      case .decodingError:
        errorMsg.wrappedValue =
          "Your \(isPhoneNumber ? "phone number" : isEmail ? "email" : "code") is incorrect. Please try again."
        Log.shared.error("Failed decodingError", error: error)
      case .networkError:
        errorMsg.wrappedValue = "Please check your connection."
        Log.shared.error("Failed networkError", error: error)
      case .rateLimited:
        errorMsg.wrappedValue = "Too many tries. Please try again after a few minutes."
        Log.shared.error("Failed rateLimited", error: error)
      case let .error(error_, errorCode, description):
        errorMsg.wrappedValue = description ?? "Unknown error"
        Log.shared.error("Failed error \(error_)", error: error)
    }
  }

  public init() {}
}
