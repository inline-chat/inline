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
    #expect(InlineDeepLink.chat(id: 34).url(scheme: "https") == nil)
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

  @Test("accepts dev and debug schemes only in debug builds")
  func acceptsDevAndDebugSchemesOnlyInDebugBuilds() {
    #if DEBUG || DEBUG_BUILD
      #expect(InlineDeepLink(url: URL(string: "inline-dev://chat/34")!) == .chat(id: 34))
      #expect(InlineDeepLink(url: URL(string: "inline-debug://thread?thread_id=34")!) == .chat(id: 34))
      #expect(InlineDeepLink.chat(id: 34).url(scheme: "inline-dev")?.absoluteString == "inline-dev://chat/34")
    #else
      #expect(InlineDeepLink(url: URL(string: "inline-dev://chat/34")!) == nil)
      #expect(InlineDeepLink(url: URL(string: "inline-debug://thread?thread_id=34")!) == nil)
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
  }
}
