import AppKit

// App services and input-command handling are stand-ins. The runner compiles the
// production ComposeTextEditor, scroll view, control modes, and line metrics.
protocol ComposeTextViewDelegate: NSTextViewDelegate {}
class ComposeNSTextView: NSTextView { func resetPastedLinks() {} }
class NonInteractiveTextField: NSTextField {
  convenience init(label: String) { self.init(labelWithString: label) }
}
struct Log {
  static func scoped(_ name: String) -> Log { Log() }
  func trace(_ message: @autoclosure () -> String) {}
  func error(_ message: String) { print(message) }
}
enum Theme {
  static let composeMinHeight: CGFloat = 44
  static let composeVerticalPadding: CGFloat = 2
  static let composeTextViewHorizontalPadding: CGFloat = 10
  static let composeOuterSpacing: CGFloat = 8
  static let composeButtonSize: CGFloat = 32
  static let messageTextFont = NSFont.systemFont(ofSize: 14)
}
enum ChatLayoutMetrics {
  static let leadingControlCenterX: CGFloat = 32
}
extension CGFloat { func isAlmostZero() -> Bool { abs(self) < 0.00001 } }
extension NSAttributedString.Key {
  static let mentionUserId = Self("mentionUserId")
  static let mentionGroupId = Self("mentionGroupId")
  static let threadLink = Self("threadLink")
  static let preCode = Self("preCode")
  static let inlineCode = Self("inlineCode")
  static let richTextUnderline = Self("richTextUnderline")
}
enum ProcessEntities {
  static func isCursorInCodeBlock(attributes: [NSAttributedString.Key: Any]) -> Bool { attributes[.preCode] != nil }
}
