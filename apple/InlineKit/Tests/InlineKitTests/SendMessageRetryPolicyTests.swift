import Foundation
import Testing
@testable import Auth
@testable import InlineKit

@Suite("Send Message Retry Policy")
struct SendMessageRetryPolicyTests {
  @Test("optimistic send skips local message when current user id is missing")
  func optimisticSkipsMissingCurrentUserId() {
    let userDefaultsKey = "\(AuthKeychainConfig.userDefaultsPrefix(mocked: false))userId"
    let previous = UserDefaults.standard.object(forKey: userDefaultsKey)
    UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    defer {
      if let previous {
        UserDefaults.standard.set(previous, forKey: userDefaultsKey)
      } else {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
      }
    }

    let transaction = TransactionSendMessage(
      text: "caption",
      peerId: .user(id: 1),
      chatId: 1,
      mediaItems: []
    )

    transaction.optimistic()
  }

  @Test("does not retry upload validation errors")
  func noRetryForUploadValidationErrors() {
    let transaction = TransactionSendMessage(
      text: nil,
      peerId: .user(id: 1),
      chatId: 1
    )

    let shouldRetry = transaction.shouldRetryOnFail(
      error: APIError.error(
        error: "PHOTO_INVALID_DIMENSIONS",
        errorCode: 400,
        description: "This image is too wide or too tall to send as a photo. Send it as a file instead."
      )
    )

    #expect(shouldRetry == false)
  }

  @Test("keeps retrying network upload failures")
  func retryForNetworkUploadFailures() {
    let transaction = TransactionSendMessage(
      text: nil,
      peerId: .user(id: 1),
      chatId: 1
    )

    #expect(transaction.shouldRetryOnFail(error: APIError.networkError))
  }

  @Test("uses server descriptions for localized api errors")
  func apiErrorLocalizedDescriptionPrefersServerMessage() {
    let error = APIError.error(
      error: "PHOTO_INVALID_DIMENSIONS",
      errorCode: 400,
      description: "This image is too wide or too tall to send as a photo. Send it as a file instead."
    )

    #expect(error.localizedDescription == "This image is too wide or too tall to send as a photo. Send it as a file instead.")
  }
}
