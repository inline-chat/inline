#if os(macOS)
import AppKit
import Testing

@testable import InlineUI

@Suite("ForwardMessagesMacKeyBindings")
struct ForwardMessagesMacKeyBindingsTests {
  @Test("control j moves to the next chat")
  func controlJMovesToNextChat() async throws {
    let action = ForwardMessagesMacKeyBindings.action(
      keyCode: 38,
      charactersIgnoringModifiers: "j",
      modifierFlags: [.control],
      isTextInputFocused: false,
      hasSearchText: false
    )

    #expect(action == .moveHighlightedChat(1))
  }

  @Test("control n shares the next chat alias")
  func controlNSharesNextChatAlias() async throws {
    let action = ForwardMessagesMacKeyBindings.action(
      keyCode: 45,
      charactersIgnoringModifiers: "n",
      modifierFlags: [.control],
      isTextInputFocused: false,
      hasSearchText: false
    )

    #expect(action == .moveHighlightedChat(1))
  }

  @Test("control k moves to the previous chat")
  func controlKMovesToPreviousChat() async throws {
    let action = ForwardMessagesMacKeyBindings.action(
      keyCode: 40,
      charactersIgnoringModifiers: "k",
      modifierFlags: [.control],
      isTextInputFocused: false,
      hasSearchText: false
    )

    #expect(action == .moveHighlightedChat(-1))
  }

  @Test("control p shares the previous chat alias")
  func controlPSharesPreviousChatAlias() async throws {
    let action = ForwardMessagesMacKeyBindings.action(
      keyCode: 35,
      charactersIgnoringModifiers: "p",
      modifierFlags: [.control],
      isTextInputFocused: false,
      hasSearchText: false
    )

    #expect(action == .moveHighlightedChat(-1))
  }

  @Test("arrow navigation still works with focused text input")
  func arrowNavigationStillWorks() async throws {
    let action = ForwardMessagesMacKeyBindings.action(
      keyCode: 125,
      charactersIgnoringModifiers: nil,
      modifierFlags: [],
      isTextInputFocused: true,
      hasSearchText: false
    )

    #expect(action == .moveHighlightedChat(1))
  }

  @Test("control vim navigation stays active while typing in search")
  func controlVimNavigationStaysActiveWhileTyping() async throws {
    let action = ForwardMessagesMacKeyBindings.action(
      keyCode: 38,
      charactersIgnoringModifiers: "j",
      modifierFlags: [.control],
      isTextInputFocused: true,
      hasSearchText: false
    )

    #expect(action == .moveHighlightedChat(1))
  }

  @Test("bare j is ignored so search typing still works")
  func bareJIsIgnored() async throws {
    let action = ForwardMessagesMacKeyBindings.action(
      keyCode: 38,
      charactersIgnoringModifiers: "j",
      modifierFlags: [],
      isTextInputFocused: false,
      hasSearchText: false
    )

    #expect(action == nil)
  }

  @Test("command modified bindings are ignored")
  func commandModifiedBindingsIgnored() async throws {
    let action = ForwardMessagesMacKeyBindings.action(
      keyCode: 38,
      charactersIgnoringModifiers: "j",
      modifierFlags: [.command],
      isTextInputFocused: false,
      hasSearchText: false
    )

    #expect(action == nil)
  }
}
#endif
