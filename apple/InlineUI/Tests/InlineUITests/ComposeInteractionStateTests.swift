import Foundation
import Testing

@testable import InlineUI

@Suite("ComposeInteractionState")
struct ComposeInteractionStateTests {
  @Test("plain text paste replaces the selected range and advances the cursor")
  func plainTextPasteReplacesSelection() async throws {
    let result = ComposePlainTextPaste.apply(
      currentText: "reply old text",
      selectedRange: NSRange(location: 6, length: 3),
      pastedText: "new"
    )

    #expect(result.text == "reply new text")
    #expect(result.selectedRange == NSRange(location: 9, length: 0))
  }

  @Test("plain text paste clamps invalid ranges before applying")
  func plainTextPasteClampsOutOfBoundsRange() async throws {
    let result = ComposePlainTextPaste.apply(
      currentText: "hello",
      selectedRange: NSRange(location: 99, length: 4),
      pastedText: " world"
    )

    #expect(result.text == "hello world")
    #expect(result.selectedRange == NSRange(location: 11, length: 0))
  }

  @Test("plain text paste uses UTF-16 cursor math for emoji content")
  func plainTextPasteHandlesEmojiSelection() async throws {
    let nsText = "Hi 👋"
    let result = ComposePlainTextPaste.apply(
      currentText: nsText,
      selectedRange: NSRange(location: 3, length: 2),
      pastedText: "🙂"
    )

    #expect(result.text == "Hi 🙂")
    #expect(result.selectedRange == NSRange(location: 5, length: 0))
  }

  @Test("visible but disabled send button is not treated as fully visible")
  func sendButtonVisibleButDisabledNeedsRecovery() async throws {
    let isFullyVisible = ComposeSendButtonState.isFullyVisible(
      isButtonVisible: true,
      isEnabled: false,
      isUserInteractionEnabled: false,
      alpha: 1.0
    )

    #expect(isFullyVisible == false)
  }

  @Test("fully interactive send button is treated as fully visible")
  func sendButtonFullyVisibleWhenInteractive() async throws {
    let isFullyVisible = ComposeSendButtonState.isFullyVisible(
      isButtonVisible: true,
      isEnabled: true,
      isUserInteractionEnabled: true,
      alpha: 1.0
    )

    #expect(isFullyVisible == true)
  }

  @Test("hide completion is ignored after a newer show wins")
  func sendButtonHideCompletionSkipsVisibleButton() async throws {
    let shouldFinalize = ComposeSendButtonState.shouldFinalizeHide(
      finished: true,
      isButtonVisible: true
    )

    #expect(shouldFinalize == false)
  }

  @Test("hide completion disables when the button stayed hidden")
  func sendButtonHideCompletionFinalizesWhenStillHidden() async throws {
    let shouldFinalize = ComposeSendButtonState.shouldFinalizeHide(
      finished: true,
      isButtonVisible: false
    )

    #expect(shouldFinalize == true)
  }

  @Test("hide completion only disables when the hide animation really finished")
  func sendButtonHideCompletionRequiresFinishedAnimation() async throws {
    let shouldFinalize = ComposeSendButtonState.shouldFinalizeHide(
      finished: false,
      isButtonVisible: false
    )

    #expect(shouldFinalize == false)
  }

  @Test("ready attachments force the send button visible immediately")
  func sendButtonShowsImmediatelyForReadyAttachments() async throws {
    let shouldShowImmediately = ComposeSendButtonState.shouldShowImmediatelyForReadyAttachments(
      hasAttachments: true,
      hasPendingVideos: false,
      canSend: true
    )

    #expect(shouldShowImmediately == true)
  }

  @Test("pending videos do not force immediate send button visibility")
  func sendButtonDoesNotShowImmediatelyForPendingVideos() async throws {
    let shouldShowImmediately = ComposeSendButtonState.shouldShowImmediatelyForReadyAttachments(
      hasAttachments: true,
      hasPendingVideos: true,
      canSend: false
    )

    #expect(shouldShowImmediately == false)
  }

  @Test("text can send while attachments are still uploading")
  func sendEligibilityAllowsTextDuringUpload() async throws {
    let canSend = ComposeSendEligibility.canSend(
      hasText: true,
      hasAttachments: true,
      hasForward: false,
      hasPendingVideos: false,
      hasActiveAttachmentUploads: true
    )

    #expect(canSend == true)
  }

  @Test("attachment-only send is allowed while pending video preprocessing is in progress")
  func sendEligibilityAllowsAttachmentOnlyDuringPendingMedia() async throws {
    let canSend = ComposeSendEligibility.canSend(
      hasText: false,
      hasAttachments: false,
      hasForward: false,
      hasPendingVideos: true,
      hasActiveAttachmentUploads: false
    )

    #expect(canSend == true)
  }

  @Test("attachment-only send is allowed while uploads are already in flight")
  func sendEligibilityAllowsAttachmentOnlyDuringUpload() async throws {
    let canSend = ComposeSendEligibility.canSend(
      hasText: false,
      hasAttachments: true,
      hasForward: false,
      hasPendingVideos: false,
      hasActiveAttachmentUploads: true
    )

    #expect(canSend == true)
  }

  @Test("pending video only can be sent")
  func sendEligibilityAllowsPendingVideoOnly() async throws {
    let canSend = ComposeSendEligibility.canSend(
      hasText: false,
      hasAttachments: false,
      hasForward: false,
      hasPendingVideos: true,
      hasActiveAttachmentUploads: false
    )

    #expect(canSend == true)
  }

  @Test("pending video sends do not fall back to text only")
  func sendEligibilityDoesNotUseTextOnlyModeWhenPendingMediaIsNotReady() async throws {
    let shouldSendTextOnly = ComposeSendEligibility.shouldSendTextOnly(
      hasText: true,
      hasPendingVideos: true,
      hasActiveAttachmentUploads: false
    )

    #expect(shouldSendTextOnly == false)
  }

  @Test("text only mode is not used when uploads are already in flight")
  func sendEligibilityDoesNotUseTextOnlyModeDuringUpload() async throws {
    let shouldSendTextOnly = ComposeSendEligibility.shouldSendTextOnly(
      hasText: true,
      hasPendingVideos: false,
      hasActiveAttachmentUploads: true
    )

    #expect(shouldSendTextOnly == false)
  }

  @Test("text only mode is not used when media is ready")
  func sendEligibilityDoesNotUseTextOnlyModeWhenMediaReady() async throws {
    let shouldSendTextOnly = ComposeSendEligibility.shouldSendTextOnly(
      hasText: true,
      hasPendingVideos: false,
      hasActiveAttachmentUploads: false
    )

    #expect(shouldSendTextOnly == false)
  }

  @Test("sending staged attachments resets compose without animation")
  func sendResetDoesNotAnimateAfterSendingAttachments() async throws {
    let shouldAnimateReset = ComposeResetBehavior.shouldAnimateHeightResetAfterSend(
      hadAttachments: true
    )

    #expect(shouldAnimateReset == false)
  }

  @Test("text-only reset keeps the existing height animation behavior")
  func sendResetCanAnimateWithoutAttachments() async throws {
    let shouldAnimateReset = ComposeResetBehavior.shouldAnimateHeightResetAfterSend(
      hadAttachments: false
    )

    #expect(shouldAnimateReset == true)
  }

  @Test("sending staged attachments hides the send button immediately")
  func sendResetHidesButtonImmediatelyAfterSendingAttachments() async throws {
    let shouldHideImmediately = ComposeResetBehavior.shouldHideSendButtonImmediatelyAfterSend(
      hadAttachments: true
    )

    #expect(shouldHideImmediately == true)
  }

  @Test("pending video send is queued until preprocessing completes")
  func pendingMediaSendQueuesWhileVideosArePending() async throws {
    let shouldQueue = ComposePendingMediaSendBehavior.shouldQueueSendUntilPendingVideosAreReady(
      hasPendingVideos: true
    )

    #expect(shouldQueue == true)
  }

  @Test("ready media sends immediately without queuing")
  func pendingMediaSendDoesNotQueueWithoutPendingVideos() async throws {
    let shouldQueue = ComposePendingMediaSendBehavior.shouldQueueSendUntilPendingVideosAreReady(
      hasPendingVideos: false
    )

    #expect(shouldQueue == false)
  }
}
