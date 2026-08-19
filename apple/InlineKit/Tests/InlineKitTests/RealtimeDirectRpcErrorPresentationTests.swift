import Foundation
import InlineKit
import InlineProtocol
import RealtimeV2
import Testing

@Suite("Realtime RPC error presentation")
struct RealtimeDirectRpcErrorPresentationTests {
  @Test("transport failures have human-readable descriptions")
  func transportFailures() {
    #expect(RealtimeDirectRpcError.notConnected.localizedDescription == "Inline is offline. Check your connection and try again.")
    #expect(RealtimeDirectRpcError.timeout.localizedDescription == "The request took too long. Try again.")
    #expect(
      RealtimeDirectRpcError.commitOutcomeUnknown.localizedDescription ==
        "Inline may have completed this action. Refresh to confirm before trying again."
    )
    #expect(RealtimeDirectRpcError.capacityExceeded.localizedDescription == "Inline is busy. Wait a moment and try again.")
    #expect(RealtimeDirectRpcError.notAuthorized.localizedDescription == "Your session has expired. Sign in again.")
  }

  @Test("public server messages take precedence")
  func serverMessagesTakePrecedence() {
    let error = RealtimeDirectRpcError.rpcError(
      errorCode: .badRequest,
      message: "Title cannot be empty",
      code: 400
    )

    #expect(error.localizedDescription == "Title cannot be empty")

    let blankMessage = RealtimeDirectRpcError.rpcError(
      errorCode: .usernameTaken,
      message: "  \n",
      code: 400
    )
    #expect(blankMessage.localizedDescription == "That username is already taken.")
  }

  @Test("legacy realtime uses the same message precedence")
  func legacyRealtimeUsesMessagePrecedence() {
    let serverMessage = RealtimeAPIError.rpcError(
      errorCode: .usernameTaken,
      message: "Choose another username",
      code: 400
    )
    let fallback = RealtimeAPIError.rpcError(
      errorCode: .messageIDInvalid,
      message: nil,
      code: 400
    )

    #expect(serverMessage.localizedDescription == "Choose another username")
    #expect(fallback.localizedDescription == "That message is no longer available.")
  }

  @Test("every defined protocol error has client fallback copy")
  func protocolFallbacks() {
    let cases: [(InlineProtocol.RpcError.Code, String)] = [
      (.badRequest, "Check the request and try again."),
      (.unauthenticated, "Your session has expired. Sign in again."),
      (.rateLimit, "Too many requests. Wait a moment and try again."),
      (.internalError, "Inline is having trouble right now. Try again."),
      (.peerIDInvalid, "That chat or person is no longer available."),
      (.messageIDInvalid, "That message is no longer available."),
      (.userIDInvalid, "That person is no longer available."),
      (.userAlreadyMember, "That person is already a member."),
      (.spaceIDInvalid, "That space is no longer available."),
      (.chatIDInvalid, "That chat is no longer available."),
      (.emailInvalid, "Enter a valid email address."),
      (.phoneNumberInvalid, "Enter a valid phone number."),
      (.spaceAdminRequired, "A space admin must do that."),
      (.spaceOwnerRequired, "The space owner must do that."),
      (.usernameInvalid, "Enter a valid username."),
      (.usernameTaken, "That username is already taken."),
      (.firstNameInvalid, "Enter a valid first name."),
      (.urlPreviewUnavailable, "This link can’t be previewed."),
    ]

    for (errorCode, expected) in cases {
      let error = RealtimeDirectRpcError.rpcError(
        errorCode: errorCode,
        message: nil,
        code: errorCode == .internalError ? 500 : 400
      )
      #expect(error.localizedDescription == expected)
    }
  }

  @Test("unknown future codes use status fallback")
  func unknownCodesUseStatusFallback() {
    let error = RealtimeDirectRpcError.rpcError(
      errorCode: .UNRECOGNIZED(999),
      message: nil,
      code: 404
    )

    #expect(error.localizedDescription == "That item is no longer available.")
  }
}
