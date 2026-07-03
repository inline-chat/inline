import UIKit

@MainActor
enum SendMessageAnimationSourceCapture {
  static func capture(
    identity: SendMessageAnimationIdentity,
    text: String,
    textView: UITextView,
    composeHeight: CGFloat
  ) -> SendMessageAnimationSource? {
    guard let window = textView.window else {
      SendMessageAnimationDiagnostics.event(
        "source unavailable-window random=\(identity.randomId) textWindow=\(textView.window != nil)"
      )
      return nil
    }

    textView.layoutIfNeeded()

    let visualText = textView.text ?? ""
    if visualText != text {
      guard !visualText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !text.isEmpty
      else {
        SendMessageAnimationDiagnostics.event(
          "source unavailable-text-normalized-mismatch random=\(identity.randomId) visualLen=\(visualText.count) sendLen=\(text.count)"
        )
        return nil
      }

      SendMessageAnimationDiagnostics.debug(
        "source text-normalized-mismatch-continuing random=\(identity.randomId) visualLen=\(visualText.count) sendLen=\(text.count) visualNewline=\(visualText.rangeOfCharacter(from: .newlines) != nil) sendNewline=\(text.rangeOfCharacter(from: .newlines) != nil)"
      )
    }

    let sourceTextFrame = textView.convert(textView.bounds, to: window)
    guard let sourceTextGeometry = textView.sendAnimationTextFrame() else {
      SendMessageAnimationDiagnostics.event(
        "source unavailable-text-geometry random=\(identity.randomId) text=[\(SendMessageAnimationDiagnostics.rect(sourceTextFrame))]"
      )
      return nil
    }
    if !sourceTextGeometry.isFullyVisible {
      SendMessageAnimationDiagnostics.debug(
        "source clipped-using-visible random=\(identity.randomId) text=[\(SendMessageAnimationDiagnostics.rect(sourceTextFrame))] fullTextLocal=[\(SendMessageAnimationDiagnostics.rect(sourceTextGeometry.textFrame))] visibleTextLocal=[\(SendMessageAnimationDiagnostics.rect(sourceTextGeometry.visibleTextFrame))] visibleOffset=[\(SendMessageAnimationDiagnostics.point(sourceTextGeometry.visibleOffsetInText))]"
      )
    }

    let sourceVisibleTextFrame = textView.convert(sourceTextGeometry.visibleTextFrame, to: window)
    let sourceTextFirstBaselineYInWindow = textView.convert(
      CGPoint(x: 0, y: sourceTextGeometry.firstBaselineY),
      to: window
    ).y
    guard sourceTextFrame.isFiniteAndVisible,
          sourceVisibleTextFrame.isFiniteAndVisible,
          sourceTextFirstBaselineYInWindow.isFinite
    else {
      SendMessageAnimationDiagnostics.event(
        "source invalid-frame random=\(identity.randomId) text=[\(SendMessageAnimationDiagnostics.rect(sourceTextFrame))] visibleText=[\(SendMessageAnimationDiagnostics.rect(sourceVisibleTextFrame))] baselineY=\(String(format: "%.1f", sourceTextFirstBaselineYInWindow))"
      )
      return nil
    }

    let sourceLineHeight = textView.font?.lineHeight ?? 20
    guard sourceLineHeight.isFinite, sourceLineHeight > 0 else {
      SendMessageAnimationDiagnostics.event(
        "source invalid-line-height random=\(identity.randomId) lineHeight=\(String(format: "%.1f", sourceLineHeight))"
      )
      return nil
    }

    SendMessageAnimationDiagnostics.debug(
      "source captured mode=unified-geometry random=\(identity.randomId) temp=\(identity.temporaryMessageId) hasNewline=\(text.rangeOfCharacter(from: .newlines) != nil) text=[\(SendMessageAnimationDiagnostics.rect(sourceTextFrame))] fullTextLocal=[\(SendMessageAnimationDiagnostics.rect(sourceTextGeometry.textFrame))] visibleTextLocal=[\(SendMessageAnimationDiagnostics.rect(sourceTextGeometry.visibleTextFrame))] visibleOffset=[\(SendMessageAnimationDiagnostics.point(sourceTextGeometry.visibleOffsetInText))] visibleText=[\(SendMessageAnimationDiagnostics.rect(sourceVisibleTextFrame))] baselineY=\(String(format: "%.1f", sourceTextFirstBaselineYInWindow)) visibleBottomY=\(String(format: "%.1f", sourceVisibleTextFrame.maxY)) lineHeight=\(String(format: "%.1f", sourceLineHeight)) composeH=\(composeHeight)"
    )

    return SendMessageAnimationSource(
      identity: identity,
      text: text,
      sourceTextFrameInWindow: sourceTextFrame,
      sourceVisibleTextFrameInWindow: sourceVisibleTextFrame,
      sourceTextFirstBaselineYInWindow: sourceTextFirstBaselineYInWindow,
      sourceLineHeight: sourceLineHeight,
      preparedAt: Date()
    )
  }
}
