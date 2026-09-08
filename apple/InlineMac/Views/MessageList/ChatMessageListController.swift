import AppKit
import InlineKit

/// The compose/route boundary shared by the stable and experimental lists.
@MainActor
protocol ChatMessageListController: NSViewController {
  var viewModel: MessagesProgressiveViewModel { get }
  var highestPositiveMessageId: Int64? { get }
  var preservesHistoryOnSend: Bool { get }
  func updateInsetForCompose(_ height: CGFloat, animate: Bool)
  func collapseHistory(maxID: Int64?) async throws
  func setCollapsedMaxId(_ collapsedMaxId: Int64?)
  func dispose()
}

extension ChatMessageListController {
  func updateInsetForCompose(_ height: CGFloat) {
    updateInsetForCompose(height, animate: true)
  }
}

extension MessageListAppKit: ChatMessageListController {
  var preservesHistoryOnSend: Bool {
    false
  }
}

enum ExperimentalMessageListFeature {
  static let key = "experimental.macMessageListV2"
  /// Parked research experiment. A saved preference must never activate it in a release build.
  static var isAvailable: Bool {
    #if DEBUG
    true
    #else
    false
    #endif
  }

  static var isEnabled: Bool {
    isAvailable && UserDefaults.standard.bool(forKey: key)
  }
}
