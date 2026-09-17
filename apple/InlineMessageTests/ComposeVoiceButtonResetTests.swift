@testable import InlineIOS
@testable import InlineKit
@testable import TextProcessing
import Testing
import UIKit

@Suite("Composer microphone after clearing", .serialized)
@MainActor
struct ComposeVoiceButtonResetTests {
  @Test("Full send reset restores microphone across repeated sends", arguments: [false, true])
  func fullSendReset(coordinated: Bool) async throws {
    let compose = makeCompose()
    for text in ["hello", "سلام\nsecond line", "another message"] {
      enterText(text, in: compose)
      compose.resetFullComposeStateAfterTextSend(
        shouldCoordinateSendAnimationReset: coordinated,
        didPrepareSendAnimationPreview: coordinated
      )
      expectMicrophone(in: compose)
    }
    // Let previous button animations finish as well as checking synchronous state.
    try await Task.sleep(for: .milliseconds(350))
    expectMicrophone(in: compose)
  }

  @Test("Reset with pending media restores microphone")
  func fullMediaReset() {
    let compose = makeCompose()
    enterText("caption", in: compose)
    compose.pendingVideoAttachments = [.init(id: "compose-reset-test", thumbnailImage: nil)]
    compose.resetFullComposeStateAfterTextSend(
      shouldCoordinateSendAnimationReset: false,
      didPrepareSendAnimationPreview: false
    )
    #expect(compose.pendingVideoAttachments.isEmpty)
    expectMicrophone(in: compose)
  }

  @Test("Text-only reset restores microphone only when no media remains", arguments: [false, true])
  func textOnlyReset(retainsMedia: Bool) {
    let compose = makeCompose()
    enterText("hello", in: compose)
    if retainsMedia {
      compose.pendingVideoAttachments = [.init(id: "retained-video", thumbnailImage: nil)]
    }
    compose.clearTextOnlyComposeAfterSend(
      shouldCoordinateSendAnimationReset: true,
      didPrepareSendAnimationPreview: true
    )
    if retainsMedia {
      #expect(compose.voiceButton.isHidden)
      #expect(!compose.sendButton.isHidden)
      #expect(compose.sendButton.isEnabled)
    } else {
      expectMicrophone(in: compose)
    }
  }

  @Test("Command and edit clears restore microphone", arguments: [false, true])
  func otherProgrammaticClears(edit: Bool) {
    let compose = makeCompose()
    enterText(edit ? "edited message" : "/command", in: compose)
    if edit {
      compose.dismissEmbed(mode: .edit)
    } else {
      compose.clearInlineCommandText()
    }
    expectMicrophone(in: compose)
  }

  private func makeCompose() -> ComposeView {
    // Exercise the real reset methods without writing drafts or sending requests.
    let drafts = Drafts()
    let persistence = DraftPersistenceClient(
      registerIntent: { drafts.registerIntent(for: $0, kind: $1) },
      isLatestIntent: { drafts.isLatestIntent($0) },
      update: { _, _, _, _ in true },
      clear: { _, _ in true }
    )
    let compose = ComposeView(
      frame: CGRect(x: 0, y: 0, width: 390, height: 100),
      draftManager: DraftManager(debounceDelay: 2, persistence: persistence)
    )
    compose.peerId = .user(id: 9_100_917)
    compose.chatId = 9_100_917
    compose.layoutIfNeeded()
    expectMicrophone(in: compose)
    return compose
  }

  private func enterText(_ text: String, in compose: ComposeView) {
    compose.textView.text = text
    compose.updateSendButtonVisibility()
    #expect(compose.voiceButton.isHidden)
    #expect(!compose.sendButton.isHidden)
    #expect(compose.sendButton.isEnabled)
  }

  private func expectMicrophone(in compose: ComposeView) {
    #expect(compose.textView.text.isEmpty)
    #expect(!compose.voiceButton.isHidden)
    #expect(compose.voiceButton.alpha == 1)
    #expect(compose.voiceButton.isUserInteractionEnabled)
    #expect(compose.sendButton.isHidden)
    #expect(!compose.sendButton.isEnabled)
    #expect(!compose.sendButton.isUserInteractionEnabled)
  }
}
