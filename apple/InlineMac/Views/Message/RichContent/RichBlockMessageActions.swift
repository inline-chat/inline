import Foundation
import InlineKit

enum RichBlockMessageActions {
  static func toggleDisclosure(
    path: BlockContentPath,
    expanded: Bool,
    message: Message
  ) {
    RichBlockLocalStateStore.shared.setDisclosure(
      expanded,
      path: path,
      message: message
    )
  }
}
