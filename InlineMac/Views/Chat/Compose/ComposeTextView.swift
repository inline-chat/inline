import AppKit

protocol ComposeTextViewDelegate: NSTextViewDelegate {
  func textViewDidPressReturn(_ textView: NSTextView) -> Bool
  func textViewDidPressCommandReturn(_ textView: NSTextView) -> Bool
}

class ComposeNSTextView: NSTextView {
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 {
      if event.modifierFlags.contains(.command) {
        if let delegate = delegate as? ComposeTextViewDelegate {
          if delegate.textViewDidPressCommandReturn(self) {
            return
          }
        }
      } else if !event.modifierFlags.contains(.shift) {
        if let delegate = delegate as? ComposeTextViewDelegate {
          if delegate.textViewDidPressReturn(self) {
            return
          }
        }
      }
    }
    super.keyDown(with: event)
  }
}
