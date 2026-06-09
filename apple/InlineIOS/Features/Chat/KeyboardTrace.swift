import Logger
import UIKit

enum KeyboardTrace {
  static let prefix = "IOS_KEYBOARD_TRACE"
  #if DEBUG
  private static let log = Log.scoped("iOS.KeyboardTrace", enableTracing: true)
  #endif

  static func trace(
    _ owner: String,
    _ event: String,
    view: UIView? = nil,
    notification: Notification? = nil,
    details: String? = nil,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    #if DEBUG
    var parts = [prefix, owner, event]

    if let notification {
      parts.append(notificationDetails(notification, in: view))
    }

    if let details, !details.isEmpty {
      parts.append(details)
    }

    log.trace(parts.joined(separator: " | "), file: file, function: function, line: line)
    #endif
  }

  static func notificationDetails(_ notification: Notification, in view: UIView?) -> String {
    let userInfo = notification.userInfo ?? [:]
    var parts = ["notification=\(notification.name.rawValue)"]

    if let beginFrame = userInfo[UIResponder.keyboardFrameBeginUserInfoKey] as? CGRect {
      parts.append("beginFrame=\(rect(beginFrame))")
      if let view, view.window != nil {
        parts.append("beginInView=\(rect(view.convert(beginFrame, from: nil)))")
      }
    }

    if let endFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
      parts.append("endFrame=\(rect(endFrame))")
      if let view, view.window != nil {
        let endInView = view.convert(endFrame, from: nil)
        parts.append("endInView=\(rect(endInView))")
        parts.append("overlap=\(format(max(0, view.bounds.maxY - endInView.minY)))")
      }
    }

    if let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double {
      parts.append("duration=\(format(duration))")
    }

    if let curve = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber {
      parts.append("curve=\(curve.intValue)")
    }

    if let isLocal = userInfo[UIResponder.keyboardIsLocalUserInfoKey] as? Bool {
      parts.append("isLocal=\(isLocal)")
    }

    return parts.joined(separator: " ")
  }

  static func constraint(_ constraint: NSLayoutConstraint?) -> String {
    guard let constraint else { return "nil" }

    return [
      "active=\(constraint.isActive)",
      "constant=\(format(constraint.constant))",
    ].joined(separator: ",")
  }

  static func textViewState(_ textView: UITextView) -> String {
    [
      "textFirstResponder=\(textView.isFirstResponder)",
      "textEditable=\(textView.isEditable)",
      "selectedRange=\(range(textView.selectedRange))",
      "textFrame=\(rect(textView.frame))",
      "contentSize=\(size(textView.contentSize))",
    ].joined(separator: " ")
  }

  static func rect(_ rect: CGRect) -> String {
    "(x:\(format(rect.origin.x)),y:\(format(rect.origin.y)),w:\(format(rect.size.width)),h:\(format(rect.size.height)))"
  }

  static func size(_ size: CGSize) -> String {
    "(w:\(format(size.width)),h:\(format(size.height)))"
  }

  static func insets(_ insets: UIEdgeInsets) -> String {
    "(top:\(format(insets.top)),left:\(format(insets.left)),bottom:\(format(insets.bottom)),right:\(format(insets.right)))"
  }

  static func range(_ range: NSRange) -> String {
    "(location:\(range.location),length:\(range.length))"
  }

  static func format(_ value: CGFloat) -> String {
    String(format: "%.1f", Double(value))
  }

  static func format(_ value: Double) -> String {
    String(format: "%.3f", value)
  }

}
