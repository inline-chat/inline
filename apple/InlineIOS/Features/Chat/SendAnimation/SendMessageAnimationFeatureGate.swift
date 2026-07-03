import UIKit

struct SendMessageAnimationEligibility {
  let hasText: Bool
  let hasAttachments: Bool
  let hasPendingVideos: Bool
  let hasActiveAttachmentUploads: Bool
  let isEditing: Bool
  let isForwarding: Bool
  let isReplying: Bool
  let isComposeFocused: Bool
  let hasWindow: Bool
  let isEmojiOnlyText: Bool

  var diagnosticSummary: String {
    "text=\(hasText) emojiOnly=\(isEmojiOnlyText) attachments=\(hasAttachments) pendingVideos=\(hasPendingVideos) uploads=\(hasActiveAttachmentUploads) editing=\(isEditing) forwarding=\(isForwarding) replying=\(isReplying) focused=\(isComposeFocused) window=\(hasWindow)"
  }
}

enum SendMessageAnimationFeatureGate {
  static var isEnabled = true

  static func shouldAttemptTextSend(_ eligibility: SendMessageAnimationEligibility) -> Bool {
    guard isEnabled else { return false }
    guard !UIAccessibility.isReduceMotionEnabled else { return false }

    return eligibility.hasText &&
      !eligibility.isEmojiOnlyText &&
      !eligibility.hasAttachments &&
      !eligibility.hasPendingVideos &&
      !eligibility.hasActiveAttachmentUploads &&
      !eligibility.isEditing &&
      !eligibility.isForwarding &&
      eligibility.isComposeFocused &&
      eligibility.hasWindow
  }
}
