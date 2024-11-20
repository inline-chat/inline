import SwiftUI

class ChatScroller: ObservableObject {
  private var scrollToMessage: ((Int64, Bool) -> Void)?
  private var scrollToBottom: ((Bool) -> Void)?

  init() {}

  func hook(
    scrollToMessage: @escaping (Int64, Bool) -> Void,
    scrollToBottom: @escaping (Bool) -> Void
  ) {
    self.scrollToMessage = scrollToMessage
    self.scrollToBottom = scrollToBottom
  }

  // Public API
  public func scrollToMessage(_ messageId: Int64, animate: Bool) {
    scrollToMessage?(messageId, animate)
  }

  public func scrollToBottom(animate: Bool) {
    scrollToBottom?(animate)
  }
}
