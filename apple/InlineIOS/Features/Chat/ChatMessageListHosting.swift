import InlineIOSUI
import InlineKit
import UIKit

/// What `ChatContainerView` asks of its message list. The container owns the composer, the
/// pinned header and the floating buttons once; the list is `MessagesCollectionView` or, behind
/// its switch, `TimelineMessagesView`.
@MainActor
protocol ChatMessageListHosting: UIView {
  var highestPositiveMessageId: Int64? { get }
  var isContextMenuInteractionActive: Bool { get }
  var isReactionPickerPresented: Bool { get }

  func updatePinnedHeaderHeight(_ height: CGFloat)
  func scrollToMessageWhenAvailable(_ messageID: Int64, requiresExactMessage: Bool)
  func cancelPendingMessageFocus()
  func setInitialComposeHeight(_ height: CGFloat)
  func collapseHistory(maxID: Int64?) async throws
  func setComposeBottomOffset(_ offset: CGFloat)
  func setCollapsedMaxId(_ collapsedMaxId: Int64?)
  func applyTheme(_ theme: IOSThemeSnapshot)
  func scrollToBottom()
  func setUnreadState(_ state: ChatActivityNavigator.State)
  func updateComposeInset(composeHeight: CGFloat, animation: ComposeHeightChangeAnimation)
  func deferComposeInsetForPendingSendAnimation(composeHeight: CGFloat)
  func cancelContextMenuKeyboardRestoration()
  func preserveContextMenuViewportForKeyboardRestoration()

  /// The compose area's top moved: the keyboard, a drag of it, the composer's height, or a
  /// layout pass. `bottomInset` is the distance from the container's bottom to the compose
  /// area's top; the list moves with `timing` in this call. Lists that follow the keyboard
  /// themselves ignore it.
  func composeAreaDidChange(bottomInset: CGFloat, timing: TimelineTiming, isInteractive: Bool)
}

extension ChatMessageListHosting {
  func scrollToMessageWhenAvailable(_ messageID: Int64) {
    scrollToMessageWhenAvailable(messageID, requiresExactMessage: false)
  }
}

/// The current list follows the keyboard from its own notifications.
extension MessagesCollectionView: ChatMessageListHosting {
  func composeAreaDidChange(bottomInset _: CGFloat, timing _: TimelineTiming, isInteractive _: Bool) {}
}
