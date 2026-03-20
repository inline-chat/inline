import Foundation

public struct ComposePlainTextPasteResult: Equatable, Sendable {
  public let text: String
  public let selectedRange: NSRange

  public init(text: String, selectedRange: NSRange) {
    self.text = text
    self.selectedRange = selectedRange
  }
}

public enum ComposePlainTextPaste {
  public static func apply(
    currentText: String,
    selectedRange: NSRange,
    pastedText: String
  ) -> ComposePlainTextPasteResult {
    let nsCurrentText = currentText as NSString
    let safeLocation = min(max(0, selectedRange.location), nsCurrentText.length)
    let safeLength = min(max(0, selectedRange.length), nsCurrentText.length - safeLocation)
    let safeRange = NSRange(location: safeLocation, length: safeLength)
    let updatedText = nsCurrentText.replacingCharacters(in: safeRange, with: pastedText)
    let cursorLocation = min(
      safeLocation + (pastedText as NSString).length,
      (updatedText as NSString).length
    )

    return ComposePlainTextPasteResult(
      text: updatedText,
      selectedRange: NSRange(location: cursorLocation, length: 0)
    )
  }
}

public enum ComposeSendButtonState {
  public static let hiddenAlphaThreshold = 0.01
  public static let visibleAlphaThreshold = 0.99

  public static func isEffectivelyHidden(alpha: Double) -> Bool {
    alpha <= hiddenAlphaThreshold
  }

  public static func isFullyVisible(
    isButtonVisible: Bool,
    isEnabled: Bool,
    isUserInteractionEnabled: Bool,
    alpha: Double
  ) -> Bool {
    isButtonVisible &&
      isEnabled &&
      isUserInteractionEnabled &&
      alpha >= visibleAlphaThreshold
  }

  public static func shouldFinalizeHide(
    finished: Bool,
    isButtonVisible: Bool
  ) -> Bool {
    finished && !isButtonVisible
  }

  public static func shouldShowImmediatelyForReadyAttachments(
    hasAttachments: Bool,
    hasPendingVideos: Bool,
    canSend: Bool
  ) -> Bool {
    hasAttachments && !hasPendingVideos && canSend
  }
}

public enum ComposeSendEligibility {
  public static func canSend(
    hasText: Bool,
    hasAttachments: Bool,
    hasForward: Bool,
    hasPendingVideos: Bool,
    hasActiveAttachmentUploads: Bool
  ) -> Bool {
    if hasText {
      return true
    }

    guard hasAttachments || hasForward || hasPendingVideos else { return false }
    return true
  }

  public static func shouldSendTextOnly(
    hasText: Bool,
    hasPendingVideos: Bool,
    hasActiveAttachmentUploads: Bool
  ) -> Bool {
    false
  }
}

public enum ComposeResetBehavior {
  public static func shouldAnimateHeightResetAfterSend(hadAttachments: Bool) -> Bool {
    !hadAttachments
  }

  public static func shouldHideSendButtonImmediatelyAfterSend(hadAttachments: Bool) -> Bool {
    hadAttachments
  }
}

public enum ComposePendingMediaSendBehavior {
  public static func shouldQueueSendUntilPendingVideosAreReady(hasPendingVideos: Bool) -> Bool {
    hasPendingVideos
  }
}
