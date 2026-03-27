#if os(macOS)
import AppKit

enum ForwardMessagesMacKeyBindings {
  enum Action: Equatable {
    case moveHighlightedChat(Int)
    case toggleHighlightedSelection
    case activateHighlightedChat
    case backspaceSearch
  }

  static func action(
    keyCode: UInt16,
    charactersIgnoringModifiers: String?,
    modifierFlags: NSEvent.ModifierFlags,
    isTextInputFocused: Bool,
    hasSearchText: Bool
  ) -> Action? {
    let relevantModifiers = modifierFlags.intersection([.command, .control, .option])

    if relevantModifiers == [.control],
       let charactersIgnoringModifiers
    {
      switch charactersIgnoringModifiers.lowercased() {
        case "j", "n":
          return .moveHighlightedChat(1)
        case "k", "p":
          return .moveHighlightedChat(-1)
        default:
          break
      }
    }

    guard relevantModifiers.isEmpty else {
      return nil
    }

    switch keyCode {
      case 125:
        return .moveHighlightedChat(1)
      case 126:
        return .moveHighlightedChat(-1)
      case 49:
        return .toggleHighlightedSelection
      case 36:
        return .activateHighlightedChat
      case 51 where !isTextInputFocused && hasSearchText:
        return .backspaceSearch
      default:
        return nil
    }
  }
}
#endif
