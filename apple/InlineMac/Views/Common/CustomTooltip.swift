import AppKit
import InlineMacUI

/// Compatibility surface for older AppKit call sites. New code should use
/// `InlineTooltipManager` or `NSView.setInlineTooltip` directly.
@available(*, deprecated, message: "Use InlineTooltipManager or NSView.setInlineTooltip directly")
@MainActor
final class SimpleTooltip {
  static let shared = SimpleTooltip()

  private init() {}

  func show(text: String, near view: NSView) {
    InlineTooltipManager.shared.show(
      InlineTooltipContent(verbatim: text),
      anchoredTo: view
    )
  }

  func hide() {
    InlineTooltipManager.shared.hide()
  }

  func hideImmediately() {
    InlineTooltipManager.shared.hideImmediately()
  }
}

extension NSView {
  func setCustomTooltip(_ text: String) {
    setInlineTooltip(verbatim: text)
  }

  func showCustomTooltip() {
    showInlineTooltip()
  }

  func removeCustomTooltip() {
    removeInlineTooltip()
  }
}
