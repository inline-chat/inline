import Foundation
import RealtimeV2
import Testing
@testable import Auth
@testable import InlineKit

@Suite("Send Message Retry Policy")
struct SendMessageRetryPolicyTests {
  private func documentSend() -> TransactionSendMessage {
    let document = Document(
      id: 42, documentId: -42, date: Date(), fileName: "boundary.zip",
      mimeType: "application/zip", size: 500_000_000, localPath: "boundary.zip"
    )
    return TransactionSendMessage(
      text: nil, peerId: .user(id: 1), chatId: 1,
      mediaItems: [.document(DocumentInfo(document: document))]
    )
  }

  @Test("large attachment sends rely on RPC stall bounds rather than an overall deadline")
  func attachmentSendHasNoOverallDeadline() {
    #expect(documentSend().config.executionTimeout == 0)
    let textSend = TransactionSendMessage(text: "hello", peerId: .user(id: 1), chatId: 1)
    #expect(textSend.config.executionTimeout == 600)
  }

  @Test("restored attachment sends discard legacy overall deadlines and preserve retry settings")
  func restoredAttachmentDiscardsLegacyDeadline() throws {
    var legacy = documentSend()
    legacy.config = TransactionConfig(maxRetries: 7, retryDelay: 3, executionTimeout: 600)
    let restored = try JSONDecoder().decode(TransactionSendMessage.self, from: JSONEncoder().encode(legacy))
    #expect(restored.config.executionTimeout == 0)
    #expect(restored.config.maxRetries == 7)
    #expect(restored.config.retryDelay == 3)
  }

  @Test("restored attachment sends without saved configuration also avoid an overall deadline")
  func restoredAttachmentWithoutConfigHasNoDeadline() throws {
    let encoded = try JSONEncoder().encode(documentSend())
    var payload = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    payload.removeValue(forKey: "config")
    let restored = try JSONDecoder().decode(
      TransactionSendMessage.self, from: JSONSerialization.data(withJSONObject: payload)
    )
    #expect(restored.config.executionTimeout == 0)
  }

  @Test("optimistic send skips local message when current user id is missing")
  func optimisticSkipsMissingCurrentUserId() {
    #expect(Auth.getCurrentUserId() == nil)

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

  @Test("native upload permanent failures do not retry")
  func nativeUploadPermanentFailures() {
    let transaction = TransactionSendMessage(text: nil, peerId: .user(id: 1), chatId: 1)
    let errors: [NativeMediaUploadError] = [
      .fileTooLarge, .emptySource, .invalidGeometry, .sourceChanged, .canceled, .expired, .processingTimedOut,
      .rejected(code: .uploadFailureInvalidMedia, retryable: false),
    ]
    for error in errors {
      #expect(!transaction.shouldRetryOnFail(error: error))
    }
    #expect(transaction.shouldRetryOnFail(error: NativeMediaUploadError.rejected(code: .uploadFailureInvalidMedia, retryable: true)))
    #expect(transaction.shouldRetryOnFail(error: NativeMediaUploadError.unexpectedResponse))
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

  @Test("keeps retrying when primary realtime disconnects after upload")
  func retryForPrimaryRealtimeDisconnect() {
    let transaction = TransactionSendMessage(
      text: nil,
      peerId: .user(id: 1),
      chatId: 1
    )

    #expect(transaction.shouldRetryOnFail(error: RealtimeDirectRpcError.notConnected))
    #expect(transaction.shouldRetryOnFail(error: RealtimeDirectRpcError.commitOutcomeUnknown))
  }

  @Test("does not retry permanent primary realtime failures")
  func noRetryForPermanentPrimaryRealtimeFailures() {
    let transaction = TransactionSendMessage(
      text: nil,
      peerId: .user(id: 1),
      chatId: 1
    )

    #expect(transaction.shouldRetryOnFail(error: RealtimeDirectRpcError.notAuthorized) == false)
    #expect(
      transaction.shouldRetryOnFail(
        error: RealtimeDirectRpcError.rpcError(errorCode: .badRequest, message: "bad request", code: 400)
      ) == false
    )
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
