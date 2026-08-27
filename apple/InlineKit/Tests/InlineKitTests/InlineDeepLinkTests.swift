import Foundation
import Testing

@testable import InlineKit

@Suite("Inline Deep Links")
struct InlineDeepLinkTests {
  @Test("builds canonical deep link URLs")
  func buildsCanonicalURLs() {
    #expect(InlineDeepLink.user(id: 12).url?.absoluteString == "in://user/12")
    #expect(InlineDeepLink.chat(id: 34).url?.absoluteString == "in://chat/34")
    #expect(InlineDeepLink.message(chatId: 34, messageId: 56).url?.absoluteString == "in://chat/34/message/56")
    #expect(InlineDeepLink.message(chatId: 34, messageId: 56).url(scheme: "inline")?.absoluteString == "inline://chat/34/message/56")
    #expect(InlineDeepLink.publicSpace(handle: "TownHall").url?.absoluteString == "in://join/public/TownHall")
    #expect(
      InlineDeepLink.spaceInvite(token: "iv1_abcdefghijklmnopqrstuvwxyz0123456789_ABCDEF").url?.absoluteString ==
        "in://join/invite/iv1_abcdefghijklmnopqrstuvwxyz0123456789_ABCDEF"
    )
    #expect(InlineDeepLink.chat(id: 34).url(scheme: "https") == nil)
  }

  @Test("isolates routable schemes by app identity")
  func isolatesRoutableSchemesByAppIdentity() {
    #expect(InlineDeepLink.appSchemes(configuredScheme: "in") == ["in", "inline"])
    #expect(InlineDeepLink.appSchemes(configuredScheme: "inline") == ["in", "inline"])
    #expect(InlineDeepLink.appSchemes(configuredScheme: "inline-debug") == ["inline-debug"])
    #expect(InlineDeepLink.appSchemes(configuredScheme: "INLINE-DEBUG-2") == ["inline-debug-2"])
    #expect(InlineDeepLink.appSchemes(configuredScheme: "inline-dev") == ["inline-dev"])
    #expect(InlineDeepLink.appSchemes(configuredScheme: "unknown") == ["in", "inline"])
  }

  @Test("builds private web shortcut URLs for chats")
  func buildsPrivateWebShortcutURLs() {
    #expect(InlineDeepLink.chat(id: 34).webURL?.absoluteString == "https://inline.chat/c/34")
    #expect(
      InlineDeepLink.chat(id: Int64.max).webURL?.absoluteString ==
        "https://inline.chat/c/9223372036854775807"
    )
    #expect(InlineDeepLink.chat(id: 0).webURL == nil)
    #expect(InlineDeepLink.user(id: 12).webURL == nil)
    #expect(InlineDeepLink.message(chatId: 34, messageId: 56).webURL == nil)
    #expect(InlineDeepLink.publicSpace(handle: "TownHall").webURL?.absoluteString == "https://inline.chat/s/TownHall")
    #expect(
      InlineDeepLink.spaceInvite(token: "iv1_abcdefghijklmnopqrstuvwxyz0123456789_ABCDEF").webURL?.absoluteString ==
        "https://inline.chat/invite/iv1_abcdefghijklmnopqrstuvwxyz0123456789_ABCDEF"
    )
  }

  @Test("parses user and chat deep links")
  func parsesUserAndChatLinks() {
    #expect(InlineDeepLink(url: URL(string: "inline://user/12")!) == .user(id: 12))
    #expect(InlineDeepLink(url: URL(string: "in://user?id=12")!) == .user(id: 12))
    #expect(InlineDeepLink(url: URL(string: "inline://chat/34")!) == .chat(id: 34))
    #expect(InlineDeepLink(url: URL(string: "inline://thread?thread_id=34")!) == .chat(id: 34))
  }

  @Test("parses message deep links")
  func parsesMessageLinks() {
    #expect(InlineDeepLink(url: URL(string: "in://chat/34/message/56")!) == .message(chatId: 34, messageId: 56))
    #expect(InlineDeepLink(url: URL(string: "inline://chat/34/message/56")!) == .message(chatId: 34, messageId: 56))
    #expect(InlineDeepLink(url: URL(string: "in://thread/34/message/56")!) == .message(chatId: 34, messageId: 56))
    #expect(InlineDeepLink(url: URL(string: "in://chat/34?message_id=56")!) == .message(chatId: 34, messageId: 56))
  }

  @Test("parses public space and private invite deep links")
  func parsesSpaceJoinLinks() {
    #expect(
      InlineDeepLink(url: URL(string: "in://join/public/TownHall")!) == .publicSpace(handle: "TownHall")
    )
    #expect(
      InlineDeepLink(url: URL(string: "in://join/invite/iv1_abcdefghijklmnopqrstuvwxyz0123456789_ABCDEF")!) ==
        .spaceInvite(token: "iv1_abcdefghijklmnopqrstuvwxyz0123456789_ABCDEF")
    )
  }

  @Test("accepts dev and debug schemes only in debug builds")
  func acceptsDevAndDebugSchemesOnlyInDebugBuilds() {
    #if DEBUG || DEBUG_BUILD || DEVBUILD_REQUIRES_SCRIPT
      #expect(InlineDeepLink(url: URL(string: "inline-dev://chat/34")!) == .chat(id: 34))
      #expect(InlineDeepLink(url: URL(string: "inline-debug://thread?thread_id=34")!) == .chat(id: 34))
      #expect(InlineDeepLink(url: URL(string: "inline-debug-2://chat/34")!) == .chat(id: 34))
      #expect(InlineDeepLink.chat(id: 34).url(scheme: "inline-dev")?.absoluteString == "inline-dev://chat/34")
    #else
      #expect(InlineDeepLink(url: URL(string: "inline-dev://chat/34")!) == nil)
      #expect(InlineDeepLink(url: URL(string: "inline-debug://thread?thread_id=34")!) == nil)
      #expect(InlineDeepLink(url: URL(string: "inline-debug-2://chat/34")!) == nil)
      #expect(InlineDeepLink.chat(id: 34).url(scheme: "inline-dev") == nil)
    #endif
  }

  @Test("rejects invalid deep links")
  func rejectsInvalidLinks() {
    #expect(InlineDeepLink(url: URL(string: "https://inline.chat/chat/34")!) == nil)
    #expect(InlineDeepLink(url: URL(string: "in://chat/0")!) == nil)
    #expect(InlineDeepLink(url: URL(string: "in://chat/34/message/0")!) == nil)
    #expect(InlineDeepLink(url: URL(string: "in://chat/34/message/56/extra")!) == nil)
    #expect(InlineDeepLink(url: URL(string: "in://chat/34/extra?message_id=56")!) == nil)
    #expect(InlineDeepLink(url: URL(string: "in://user/12/extra")!) == nil)
    #expect(InlineDeepLink(url: URL(string: "in://message/34/56")!) == nil)
    #expect(InlineDeepLink(url: URL(string: "in://message/user/12/56")!) == nil)
    #expect(InlineDeepLink(url: URL(string: "in://message?user_id=12&message_id=56")!) == nil)
    #expect(InlineDeepLink.chat(id: -1).url == nil)
    #expect(InlineDeepLink(url: URL(string: "in://join/public/a")!) == nil)
    #expect(InlineDeepLink(url: URL(string: "in://join/public/Town%20Hall")!) == nil)
    #expect(InlineDeepLink(url: URL(string: "in://join/invite/short")!) == nil)
    #expect(InlineDeepLink(url: URL(string: "in://join/invite/iv1_abcdefghijklmnopqrstuvwxyz0123456789_ABCDE!")!) == nil)
    #expect(InlineDeepLink(url: URL(string: "in://join/public/TownHall/extra")!) == nil)
  }
}
