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
}
