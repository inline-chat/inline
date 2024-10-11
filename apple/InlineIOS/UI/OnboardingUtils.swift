import Foundation
import HeadlineKit
import SwiftUI

public class OnboardingUtils: @unchecked Sendable {
    public static var shared = OnboardingUtils()

    public var hPadding: CGFloat = 50
    public var buttonBottomPadding: CGFloat = 18

    public func showError(error: APIError, errorMsg: Binding<String>) {
        switch error {
        case .invalidURL:
            Log.shared.error("Failed invalidURL", error: error)
        case .invalidResponse:
            errorMsg.wrappedValue = "Your \(Navigation.shared.activeDestination == .email() ? "email" : "code") is incorrect. Please try again."
        case .httpError(let statusCode):
            Log.shared.error("Failed httpError \(statusCode)", error: error)
        case .decodingError:
            errorMsg.wrappedValue = "Your \(Navigation.shared.activeDestination == .email() ? "email" : "code") is incorrect. Please try again."
        case .networkError:
            errorMsg.wrappedValue = "Please check your connection."
        case .rateLimited:
            errorMsg.wrappedValue = "Too many tries. Please try again after a few minutes."
        }
    }

    public init() {}
}
