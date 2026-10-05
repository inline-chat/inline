import Auth
import InlineConfig
import InlineKit
import InlineTheme
import Testing
import UIKit
@testable import InlineIOS

@Suite("Voice message source focus", .serialized)
@MainActor
struct VoiceMessageFocusTests {
  @Test("a loading source chat is replaced or reused without a duplicate push",
        arguments: ["ordinary", "voice", "coordinate", "different", "root"])
  func sourceRouteDeduplication(kind: String) {
    let peer = Peer.user(id: 9_007)
    let router = Router(initialTab: .chats, persistence: .externallyManaged, restoresPersistedState: false)
    let destination = Destination.voiceMessage(peer: peer, messageID: 123)
    let original: Destination? = switch kind {
    case "ordinary": .chat(peer: peer)
    case "voice": destination
    case "coordinate": .chatMessage(peer: peer, messageID: 50)
    case "different": .chat(peer: .user(id: 9_008))
    default: nil
    }
    router[.chats] = original.map { [$0] } ?? []
    let initialRevision = router.persistenceRevision
    VoicePlaybackNavigation.routeToSource(peer: peer, messageID: 123, router: router)
    if kind == "different", let original {
      #expect(router.selectedTabPath == [original, destination])
    } else {
      #expect(router.selectedTabPath == [destination])
    }
    if kind == "voice" { #expect(router.persistenceRevision == initialRevision) }
  }

  @Test("an unchanged nil route focus preserves a pending pill jump")
  func ordinaryChatUpdatePreservesVoiceFocus() throws {
    try requireIsolatedHost()
    let view = makeChat()
    let list = try #require(view.subviews.compactMap { $0 as? MessagesCollectionView }.first)
    defer { list.cancelPendingMessageFocus() }
    list.scrollToMessageWhenAvailable(123, requiresExactMessage: true)
    #expect(list.pendingMessageFocusIDForTesting == 123)
    view.focusMessage(nil, requestRevision: 0, requiresExactMessage: false)
    #expect(list.pendingMessageFocusIDForTesting == 123)
  }

  @Test("removing an explicit route focus still cancels its request")
  func explicitRouteRemovalCancels() throws {
    try requireIsolatedHost()
    let view = makeChat()
    let list = try #require(view.subviews.compactMap { $0 as? MessagesCollectionView }.first)
    defer { list.cancelPendingMessageFocus() }
    view.focusMessage(123, requestRevision: 0, requiresExactMessage: true)
    #expect(list.pendingMessageFocusIDForTesting == 123)
    view.focusMessage(nil, requestRevision: 0, requiresExactMessage: false)
    #expect(list.pendingMessageFocusIDForTesting == nil)
  }

  @Test("collapsed voice sources never start a neighboring-coordinate jump", arguments: [true, false])
  func collapsedMessageAdmission(exact: Bool) throws {
    try requireIsolatedHost()
    let view = makeChat(collapsedMaxId: 200)
    let list = try #require(view.subviews.compactMap { $0 as? MessagesCollectionView }.first)
    defer { list.cancelPendingMessageFocus() }
    let originalOffset = list.contentOffset
    list.scrollToMessageWhenAvailable(123, requiresExactMessage: exact)
    #expect(list.pendingMessageFocusIDForTesting == (exact ? nil : 123))
    #expect(list.contentOffset == originalOffset)
  }

  private func makeChat(collapsedMaxId: Int64? = nil) -> ChatContainerView {
    ChatContainerView(
      peerId: .user(id: 9_007), chatId: 9_007, spaceId: nil, collapsedMaxId: collapsedMaxId,
      theme: ThemeManager.shared.snapshot(variant: .light)
    )
  }

  private func requireIsolatedHost() throws {
    let isTest = TestProcess.isRunning
    try #require(isTest)
    let accountIsIsolated = !Auth.shared.getIsLoggedIn() && Auth.shared.getCurrentUserId() == nil
    try #require(accountIsIsolated)
    let databaseIsIsolated = !AppDatabase.shared.isPersistent
    try #require(databaseIsIsolated)
  }
}
