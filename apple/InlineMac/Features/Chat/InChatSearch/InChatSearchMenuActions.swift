import AppKit

/// Edit > Find actions sent through the responder chain, so the chat pane that holds focus
/// (main chat or reply thread) answers them. With no chat in the chain the items disable.
@MainActor
@objc protocol InChatSearchMenuActions {
  func showInChatSearch(_ sender: Any?)
  func findNextInChat(_ sender: Any?)
  func findPreviousInChat(_ sender: Any?)
}
