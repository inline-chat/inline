import UIKit

extension ComposeView {
  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    guard let key = presses.first?.key else {
      super.pressesBegan(presses, with: event)
      return
    }

    guard key.modifierFlags.isEmpty else {
      super.pressesBegan(presses, with: event)
      return
    }

    var keyString = ""
    switch key.keyCode {
      case .keyboardUpArrow:
        keyString = "ArrowUp"
      case .keyboardDownArrow:
        keyString = "ArrowDown"
      case .keyboardReturnOrEnter:
        keyString = "Enter"
      case .keyboardTab:
        keyString = "Tab"
      case .keyboardEscape:
        keyString = "Escape"
      default:
        super.pressesBegan(presses, with: event)
        return
    }

    if autocompleteManager?.handleKeyPress(keyString) == true {
      return
    }

    super.pressesBegan(presses, with: event)
  }
}
