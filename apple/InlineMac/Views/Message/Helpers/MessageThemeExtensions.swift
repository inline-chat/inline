import AppKit
import InlineKit

extension Message {
  // MARK: - Colors

  private var textColor: NSColor {
    if outgoing {
      NSColor.white
    } else {
      NSColor.labelColor
    }
  }
}
