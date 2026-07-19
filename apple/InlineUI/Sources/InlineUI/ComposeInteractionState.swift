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
    if hasActiveAttachmentUploads, hasAttachments || hasForward {
      return false
    }

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

public enum ComposeVoiceRecordingEligibility {
  public static func canStart(
    hasText: Bool,
    hasAttachments: Bool,
    hasPendingVideos: Bool,
    isEditing: Bool,
    isForwarding: Bool,
    hasPeer: Bool,
    hasChat: Bool,
    isVoiceActive: Bool
  ) -> Bool {
    guard hasPeer, hasChat else { return false }
    guard !isVoiceActive else { return false }
    guard !hasText else { return false }
    guard !hasAttachments else { return false }
    guard !hasPendingVideos else { return false }
    guard !isEditing else { return false }
    guard !isForwarding else { return false }

    return true
  }
}

public enum ComposeTrailingControlState: Equatable, Sendable {
  case send
  case voice
  case none

  public static func resolve(
    canSend: Bool,
    canStartVoiceRecording: Bool,
    isVoiceActive: Bool
  ) -> ComposeTrailingControlState {
    if isVoiceActive {
      return .none
    }

    if canSend {
      return .send
    }

    if canStartVoiceRecording {
      return .voice
    }

    return .none
  }
}

public enum ComposeAttachmentUploadBehavior {
  public static func shouldStartUploadsInCompose() -> Bool {
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

public struct ComposePendingMediaSendState: Equatable, Sendable {
  public private(set) var isAwaitingSend = false

  public init() {}

  public mutating func beginWaiting() -> Bool {
    guard !isAwaitingSend else { return false }
    isAwaitingSend = true
    return true
  }

  public mutating func cancel() -> Bool {
    guard isAwaitingSend else { return false }
    isAwaitingSend = false
    return true
  }

  public mutating func consumeSendIfReady(hasPendingMedia: Bool) -> Bool {
    guard isAwaitingSend, !hasPendingMedia else { return false }
    isAwaitingSend = false
    return true
  }
}

@MainActor
public final class ComposePendingMediaSendWatchdog {
  private let timeout: Duration
  private var timeoutTask: Task<Void, Never>?

  public init(timeout: Duration) {
    self.timeout = timeout
  }

  deinit {
    timeoutTask?.cancel()
  }

  public func schedule(
    onTimeout: @escaping @MainActor @Sendable () -> Void
  ) {
    cancel()
    let timeout = timeout
    timeoutTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return
      }
      guard !Task.isCancelled, let self else { return }
      timeoutTask = nil
      onTimeout()
    }
  }

  public func cancel() {
    timeoutTask?.cancel()
    timeoutTask = nil
  }
}
