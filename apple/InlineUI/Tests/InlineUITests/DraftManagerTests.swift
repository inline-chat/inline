import Foundation
import InlineKit
import InlineProtocol
import Testing
@testable import TextProcessing

@Suite("DraftManager")
@MainActor
struct DraftManagerTests {
  @Test("plain text drafts do not persist empty entities")
  func plainTextDraftsDoNotPersistEmptyEntities() {
    let manager = DraftManager(debounceDelay: 0)
    let payload = manager.makePayload(
      peerId: .user(id: 1),
      attributedString: NSAttributedString(string: "hello")
    )

    guard case let .update(_, text, entities, _) = payload else {
      Issue.record("Expected draft update")
      return
    }

    #expect(text == "hello")
    #expect(entities == nil)
  }

  @Test("empty drafts clear stored draft")
  func emptyDraftsClearStoredDraft() {
    let manager = DraftManager(debounceDelay: 0)
    let payload = manager.makePayload(
      peerId: .user(id: 1),
      attributedString: NSAttributedString(string: "  \n")
    )

    guard case .clear = payload else {
      Issue.record("Expected draft clear")
      return
    }
  }

  @Test("current attributed entities are saved")
  func currentAttributedEntitiesAreSaved() {
    let manager = DraftManager(debounceDelay: 0)
    let text = "hello mo"
    let attributedString = NSMutableAttributedString(string: text)
    attributedString.addAttribute(
      .mentionUserId,
      value: Int64(42),
      range: NSRange(location: 6, length: 2)
    )

    let payload = manager.makePayload(peerId: .user(id: 1), attributedString: attributedString)

    guard case let .update(_, _, entities, _) = payload else {
      Issue.record("Expected draft update")
      return
    }

    #expect(entities?.entities.count == 1)
    #expect(entities?.entities.first?.offset == 6)
    #expect(entities?.entities.first?.length == 2)
  }

  @Test("loaded entities are preserved until edited")
  func loadedEntitiesArePreservedUntilEdited() {
    let manager = DraftManager(debounceDelay: 0)
    manager.markLoaded(text: "hello mo", entities: mentionEntities(offset: 6, length: 2))

    let payload = manager.makePayload(
      peerId: .user(id: 1),
      attributedString: NSAttributedString(string: "hello mo!")
    )

    guard case let .update(_, text, entities, _) = payload else {
      Issue.record("Expected draft update")
      return
    }

    #expect(text == "hello mo!")
    #expect(entities?.entities.count == 1)
  }

  @Test("overlapping loaded entity edits drop stale entities")
  func overlappingLoadedEntityEditsDropStaleEntities() {
    let manager = DraftManager(debounceDelay: 0)
    manager.markLoaded(text: "hello mo", entities: mentionEntities(offset: 6, length: 2))
    manager.invalidateLoadedEntities(overlapping: NSRange(location: 6, length: 2))

    let payload = manager.makePayload(
      peerId: .user(id: 1),
      attributedString: NSAttributedString(string: "hello xx")
    )

    guard case let .update(_, text, entities, _) = payload else {
      Issue.record("Expected draft update")
      return
    }

    #expect(text == "hello xx")
    #expect(entities == nil)
  }

  @Test("zero length edits inside loaded entity drop stale entities")
  func zeroLengthEditsInsideLoadedEntityDropStaleEntities() {
    let manager = DraftManager(debounceDelay: 0)
    manager.markLoaded(text: "hello mo", entities: mentionEntities(offset: 6, length: 2))
    manager.invalidateLoadedEntities(overlapping: NSRange(location: 7, length: 0))

    let payload = manager.makePayload(
      peerId: .user(id: 1),
      attributedString: NSAttributedString(string: "hello m!o")
    )

    guard case let .update(_, text, entities, _) = payload else {
      Issue.record("Expected draft update")
      return
    }

    #expect(text == "hello m!o")
    #expect(entities == nil)
  }

  private func mentionEntities(offset: Int64, length: Int64) -> MessageEntities {
    var entity = MessageEntity()
    entity.type = .mention
    entity.offset = offset
    entity.length = length
    entity.mention = MessageEntity.MessageEntityMention.with {
      $0.userID = 42
    }

    return MessageEntities.with {
      $0.entities = [entity]
    }
  }
}
