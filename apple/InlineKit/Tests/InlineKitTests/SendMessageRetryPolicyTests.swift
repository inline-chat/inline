import Testing
@testable import InlineKit

@Suite("Send Message Retry Policy")
struct SendMessageRetryPolicyTests {
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
