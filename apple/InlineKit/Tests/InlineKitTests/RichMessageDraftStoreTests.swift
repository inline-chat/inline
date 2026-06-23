import Foundation
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Rich message draft store", .serialized)
struct RichMessageDraftStoreTests {
  private let store = RichMessageDraftStore.shared
  private let peer = Peer.thread(id: 42)
  private let now = Date(timeIntervalSince1970: 1_782_129_600)

  @Test("keeps first message binding for later draft updates")
  func keepsMessageBindingForLaterDraftUpdates() {
    store.removeAllForTesting()

    let first = update(
      draftId: "chatgpt:test-binding",
      messageId: 10,
      text: "first",
      expiresAt: now.addingTimeInterval(30)
    )
    let second = update(
      draftId: "chatgpt:test-binding",
      messageId: nil,
      text: "second",
      expiresAt: now.addingTimeInterval(30)
    )

    let firstChanges = store.apply(first, now: now)
    let secondChanges = store.apply(second, now: now)
    let snapshot = store.snapshot(for: peer, messageId: 10, now: now)

    #expect(firstChanges.map(\.key) == [RichMessageDraftMessageKey(peer: peer, messageId: 10)])
    #expect(secondChanges.map(\.key) == [RichMessageDraftMessageKey(peer: peer, messageId: 10)])
    #expect(snapshot?.draftId == "chatgpt:test-binding")
    #expect(snapshot?.richText.fallbackText == "second")
  }

  @Test("normalizes draft ids before storing")
  func normalizesDraftIDsBeforeStoring() {
    store.removeAllForTesting()

    let changes = store.apply(
      update(
        draftId: "  chatgpt:test-normalize  ",
        messageId: 18,
        text: "trimmed",
        expiresAt: now.addingTimeInterval(30)
      ),
      now: now
    )
    let snapshot = store.snapshot(for: peer, messageId: 18, now: now)

    #expect(changes.map(\.key) == [RichMessageDraftMessageKey(peer: peer, messageId: 18)])
    #expect(snapshot?.draftId == "chatgpt:test-normalize")
    #expect(snapshot?.richText.fallbackText == "trimmed")

    let clearChanges = store.apply(
      clearUpdate(draftId: "  chatgpt:test-normalize  "),
      now: now.addingTimeInterval(1)
    )

    #expect(clearChanges.map(\.key) == [RichMessageDraftMessageKey(peer: peer, messageId: 18)])
    #expect(clearChanges.first?.snapshot == nil)
    #expect(store.snapshot(for: peer, messageId: 18, now: now.addingTimeInterval(1)) == nil)
  }

  @Test("ignores empty and oversized draft ids")
  func ignoresEmptyAndOversizedDraftIDs() {
    store.removeAllForTesting()

    let emptyChanges = store.apply(
      update(
        draftId: " \t\n ",
        messageId: 19,
        text: "empty",
        expiresAt: now.addingTimeInterval(30)
      ),
      now: now
    )
    let oversizedChanges = store.apply(
      update(
        draftId: String(repeating: "x", count: 257),
        messageId: 20,
        text: "oversized",
        expiresAt: now.addingTimeInterval(30)
      ),
      now: now
    )

    #expect(emptyChanges.isEmpty)
    #expect(oversizedChanges.isEmpty)
    #expect(store.snapshot(for: peer, messageId: 19, now: now) == nil)
    #expect(store.snapshot(for: peer, messageId: 20, now: now) == nil)
  }

  @Test("missing message id does not inherit a binding across peers")
  func missingMessageIDDoesNotInheritBindingAcrossPeers() {
    store.removeAllForTesting()

    _ = store.apply(
      update(
        draftId: "chatgpt:test-peer-binding",
        messageId: 21,
        text: "original peer",
        expiresAt: now.addingTimeInterval(30)
      ),
      now: now
    )

    let changes = store.apply(
      update(
        draftId: "chatgpt:test-peer-binding",
        peerID: protocolPeer(chatID: 43),
        messageId: nil,
        text: "wrong peer",
        expiresAt: now.addingTimeInterval(30)
      ),
      now: now.addingTimeInterval(1)
    )

    #expect(changes.isEmpty)
    #expect(store.snapshot(for: peer, messageId: 21, now: now.addingTimeInterval(1))?.richText.fallbackText == "original peer")
    #expect(store.snapshot(for: .thread(id: 43), messageId: 21, now: now.addingTimeInterval(1)) == nil)
  }

  @Test("clear removes the bound draft")
  func clearRemovesBoundDraft() {
    store.removeAllForTesting()

    _ = store.apply(
      update(
        draftId: "chatgpt:test-clear",
        messageId: 11,
        text: "visible",
        expiresAt: now.addingTimeInterval(30)
      ),
      now: now
    )

    let changes = store.apply(
      clearUpdate(draftId: "chatgpt:test-clear"),
      now: now.addingTimeInterval(1)
    )

    #expect(changes.map(\.key) == [RichMessageDraftMessageKey(peer: peer, messageId: 11)])
    #expect(changes.first?.snapshot == nil)
    #expect(store.snapshot(for: peer, messageId: 11, now: now.addingTimeInterval(1)) == nil)
  }

  @Test("missing rich text removes the bound draft")
  func missingRichTextRemovesBoundDraft() {
    store.removeAllForTesting()

    _ = store.apply(
      update(
        draftId: "chatgpt:test-empty",
        messageId: 12,
        text: "visible",
        expiresAt: now.addingTimeInterval(30)
      ),
      now: now
    )

    let changes = store.apply(
      updateWithoutRichText(draftId: "chatgpt:test-empty"),
      now: now.addingTimeInterval(1)
    )

    #expect(changes.map(\.key) == [RichMessageDraftMessageKey(peer: peer, messageId: 12)])
    #expect(changes.first?.snapshot == nil)
    #expect(store.snapshot(for: peer, messageId: 12, now: now.addingTimeInterval(1)) == nil)
  }

  @Test("expired update removes the bound draft")
  func expiredUpdateRemovesBoundDraft() {
    store.removeAllForTesting()

    _ = store.apply(
      update(
        draftId: "chatgpt:test-expired-update",
        messageId: 13,
        text: "visible",
        expiresAt: now.addingTimeInterval(30)
      ),
      now: now
    )

    let changes = store.apply(
      update(
        draftId: "chatgpt:test-expired-update",
        messageId: nil,
        text: "stale",
        expiresAt: now.addingTimeInterval(-1)
      ),
      now: now
    )

    #expect(changes.map(\.key) == [RichMessageDraftMessageKey(peer: peer, messageId: 13)])
    #expect(changes.first?.snapshot == nil)
    #expect(store.snapshot(for: peer, messageId: 13, now: now) == nil)
  }

  @Test("latest active draft wins for a message")
  func latestActiveDraftWinsForMessage() {
    store.removeAllForTesting()

    _ = store.apply(
      update(
        draftId: "chatgpt:test-latest-a",
        messageId: 14,
        text: "older",
        expiresAt: now.addingTimeInterval(30)
      ),
      now: now
    )
    _ = store.apply(
      update(
        draftId: "openclaw:test-latest-b",
        messageId: 14,
        text: "newer",
        expiresAt: now.addingTimeInterval(30)
      ),
      now: now.addingTimeInterval(1)
    )

    let snapshot = store.snapshot(for: peer, messageId: 14, now: now.addingTimeInterval(1))

    #expect(snapshot?.draftId == "openclaw:test-latest-b")
    #expect(snapshot?.richText.fallbackText == "newer")
  }

  @Test("rebinding a draft reports old and new messages")
  func rebindingDraftReportsOldAndNewMessages() {
    store.removeAllForTesting()

    _ = store.apply(
      update(
        draftId: "chatgpt:test-rebind",
        messageId: 16,
        text: "first message",
        expiresAt: now.addingTimeInterval(30)
      ),
      now: now
    )

    let changes = store.apply(
      update(
        draftId: "chatgpt:test-rebind",
        messageId: 17,
        text: "second message",
        expiresAt: now.addingTimeInterval(30)
      ),
      now: now.addingTimeInterval(1)
    )

    #expect(changes.map(\.key) == [
      RichMessageDraftMessageKey(peer: peer, messageId: 16),
      RichMessageDraftMessageKey(peer: peer, messageId: 17),
    ])
    #expect(changes.first?.snapshot == nil)
    #expect(changes.last?.snapshot?.draftId == "chatgpt:test-rebind")
    #expect(store.snapshot(for: peer, messageId: 16, now: now.addingTimeInterval(1)) == nil)
    #expect(store.snapshot(for: peer, messageId: 17, now: now.addingTimeInterval(1))?.richText.fallbackText == "second message")
  }

  @Test("explicit message id can rebind a draft across peers")
  func explicitMessageIDCanRebindAcrossPeers() {
    store.removeAllForTesting()

    _ = store.apply(
      update(
        draftId: "chatgpt:test-peer-rebind",
        messageId: 22,
        text: "first peer",
        expiresAt: now.addingTimeInterval(30)
      ),
      now: now
    )

    let changes = store.apply(
      update(
        draftId: "chatgpt:test-peer-rebind",
        peerID: protocolPeer(chatID: 43),
        messageId: 23,
        text: "second peer",
        expiresAt: now.addingTimeInterval(30)
      ),
      now: now.addingTimeInterval(1)
    )

    #expect(changes.map(\.key) == [
      RichMessageDraftMessageKey(peer: peer, messageId: 22),
      RichMessageDraftMessageKey(peer: .thread(id: 43), messageId: 23),
    ])
    #expect(changes.first?.snapshot == nil)
    #expect(changes.last?.snapshot?.draftId == "chatgpt:test-peer-rebind")
    #expect(store.snapshot(for: peer, messageId: 22, now: now.addingTimeInterval(1)) == nil)
    #expect(store.snapshot(for: .thread(id: 43), messageId: 23, now: now.addingTimeInterval(1))?.richText.fallbackText == "second peer")
  }

  @Test("expiry removes stale drafts and reports affected messages")
  func expiryRemovesStaleDrafts() {
    store.removeAllForTesting()

    _ = store.apply(
      update(
        draftId: "chatgpt:test-expiry",
        messageId: 15,
        text: "expiring",
        expiresAt: now.addingTimeInterval(5)
      ),
      now: now
    )

    #expect(store.nextExpiryDate(now: now) == now.addingTimeInterval(5))

    let changes = store.removeExpired(now: now.addingTimeInterval(6))

    #expect(changes.map(\.key) == [RichMessageDraftMessageKey(peer: peer, messageId: 15)])
    #expect(changes.first?.snapshot == nil)
    #expect(store.snapshot(for: peer, messageId: 15, now: now.addingTimeInterval(6)) == nil)
  }

  private func update(
    draftId: String,
    peerID: InlineProtocol.Peer? = nil,
    messageId: Int64?,
    text: String,
    expiresAt: Date
  ) -> UpdateRichMessageDraft {
    UpdateRichMessageDraft.with {
      $0.draftID = draftId
      $0.peerID = peerID ?? protocolPeer
      $0.senderUserID = 2
      if let messageId {
        $0.messageID = messageId
      }
      $0.richText = richText(text)
      $0.expiresAt = Int64(expiresAt.timeIntervalSince1970)
    }
  }

  private func clearUpdate(draftId: String) -> UpdateRichMessageDraft {
    UpdateRichMessageDraft.with {
      $0.draftID = draftId
      $0.peerID = protocolPeer
      $0.senderUserID = 2
      $0.clear = true
    }
  }

  private func updateWithoutRichText(draftId: String) -> UpdateRichMessageDraft {
    UpdateRichMessageDraft.with {
      $0.draftID = draftId
      $0.peerID = protocolPeer
      $0.senderUserID = 2
      $0.expiresAt = Int64(now.addingTimeInterval(30).timeIntervalSince1970)
    }
  }

  private var protocolPeer: InlineProtocol.Peer {
    protocolPeer(chatID: 42)
  }

  private func protocolPeer(chatID: Int64) -> InlineProtocol.Peer {
    InlineProtocol.Peer.with {
      $0.type = .chat(.with { chat in
        chat.chatID = chatID
      })
    }
  }

  private func richText(_ text: String) -> RichMessage {
    RichMessage.with {
      $0.version = 1
      $0.direction = .directionAuto
      $0.fallbackText = text
    }
  }
}
