import Foundation
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Block content state across snapshots")
struct BlockContentStateTests {
  private let first = BlockContentPath([.block(0)])
  private let second = BlockContentPath([.block(1)])
  private let third = BlockContentPath([.block(2)])

  @Test("an inserted disclosure does not inherit expansion from the previous occupant")
  func disclosureInsertion() {
    let old = content([disclosure(0, 3)])
    let new = content([disclosure(0, 3), disclosure(4, 3)])
    var state = BlockContentDisclosureState()
    state.set(true, path: first, content: BlockContentPayload(old), source: "old")

    let result = reconcile(old, "old", new, "new old")
    #expect(result.previousPathByCurrentPath[second] == first)
    #expect(result.previousPathByCurrentPath[first] == nil)
    #expect(state.overrides(content: BlockContentPayload(new), source: "new old") == [second: true])
    // The cache key and planner read the same store in succession.
    #expect(state.overrides(content: BlockContentPayload(new), source: "new old") == [second: true])
  }

  @Test("equal ranges do not make a new title the same disclosure")
  func equalShapeReplacement() {
    let blocks = content([disclosure(0, 3)])
    var state = BlockContentDisclosureState()
    state.set(true, path: first, content: BlockContentPayload(blocks), source: "old")
    #expect(reconcile(blocks, "old", blocks, "new").previousPathByCurrentPath.isEmpty)
    #expect(state.overrides(content: BlockContentPayload(blocks), source: "new").isEmpty)
  }

  @Test("appending children preserves a unique disclosure's explicit closed state")
  func streamedChildren() {
    let old = content([disclosure(0, 3)])
    let new = content([disclosure(0, 3, children: [.with { $0.paragraph = text(4, 4) }])])
    var state = BlockContentDisclosureState()
    state.set(false, path: first, content: BlockContentPayload(old), source: "old")
    #expect(state.overrides(content: BlockContentPayload(new), source: "old body") == [first: false])
    #expect(reconcile(old, "old", new, "old body").previousPathByCurrentPath[first] == first)
  }

  @Test("duplicate titles toggle independently but never guess identity across an edit")
  func duplicateTitles() {
    let old = content([disclosure(0, 4), disclosure(5, 4)])
    var state = BlockContentDisclosureState()
    state.set(true, path: first, content: BlockContentPayload(old), source: "same same")
    state.set(false, path: second, content: BlockContentPayload(old), source: "same same")
    #expect(state.overrides(content: BlockContentPayload(old), source: "same same") == [first: true, second: false])
    let new = content([disclosure(0, 4), disclosure(5, 4), disclosure(10, 4)])
    #expect(state.overrides(content: BlockContentPayload(new), source: "same same same").isEmpty)
    #expect(reconcile(old, "same same", new, "same same same").previousPathByCurrentPath.isEmpty)
  }

  @Test("nested disclosures move using canonical UTF-16 slices")
  func nestedUnicodeDisclosure() {
    let old = content([.with { $0.quote = .with { $0.children = [disclosure(2, 3)] } }])
    let new = content([
      .with { $0.paragraph = text(0, 5) },
      .with { $0.quote = .with { $0.children = [disclosure(7, 3)] } },
    ])
    let oldPath = BlockContentPath([.block(0), .block(0)])
    let newPath = BlockContentPath([.block(1), .block(0)])
    var state = BlockContentDisclosureState()
    state.set(true, path: oldPath, content: BlockContentPayload(old), source: "😀old")
    #expect(state.overrides(content: BlockContentPayload(new), source: "intro😀old") == [newPath: true])
    #expect(reconcile(old, "😀old", new, "intro😀old").previousPathByCurrentPath[newPath] == oldPath)
  }

  @Test("invalid or split-surrogate summary ranges cannot acquire state")
  func invalidRanges() {
    for range in [text(-1, 1), text(0, Int64.max), text(1, 1), text(0, 1)] {
      let blocks = content([.with { $0.disclosure = .with { $0.summary = range } }])
      var state = BlockContentDisclosureState()
      state.set(true, path: first, content: BlockContentPayload(blocks), source: "😀")
      #expect(state.overrides(content: BlockContentPayload(blocks), source: "😀").isEmpty)
    }
  }

  @Test("removing rich content clears overrides instead of resurrecting them later")
  func removedProjection() {
    let blocks = content([disclosure(0, 3)])
    var state = BlockContentDisclosureState()
    state.set(true, path: first, content: BlockContentPayload(blocks), source: "old")
    #expect(state.overrides(content: nil, source: "old").isEmpty)
    #expect(state.overrides(content: BlockContentPayload(blocks), source: "old").isEmpty)
  }

  @Test("table state follows its unique header while rows stream")
  func tableMoveAndAppend() {
    let old = content([table(header: text(0, 3))])
    let new = content([table(header: text(0, 3)), table(header: text(4, 3), body: text(8, 4))])
    let result = reconcile(old, "old", new, "new old body")
    #expect(result.previousPathByCurrentPath[first] == nil)
    #expect(result.previousPathByCurrentPath[second] == first)
    let replacement = reconcile(old, "old", old, "new")
    #expect(replacement.previousPathByCurrentPath.isEmpty)
  }

  @Test("album insertion retains each unique ordered photo sequence")
  func albumInsertion() {
    let old = content([album([10, 11]), album([20, 21])])
    let new = content([album([30, 31]), album([10, 11]), album([20, 21])])
    let result = reconcile(old, "", new, "")
    #expect(result.previousPathByCurrentPath[first] == nil)
    #expect(result.previousPathByCurrentPath[second] == first)
    #expect(result.previousPathByCurrentPath[third] == second)
    #expect(Set(result.previousPathByCurrentPath.values).count == result.previousPathByCurrentPath.count)
  }

  @Test("album append preserves the viewport but replacement and reorder reset it")
  func albumPrefix() {
    let old = content([album([10, 11])])
    #expect(reconcile(old, "", content([album([10, 11, 12])]), "").previousPathByCurrentPath[first] == first)
    #expect(reconcile(old, "", content([album([10, 12])]), "").previousPathByCurrentPath[first] == nil)
    #expect(reconcile(old, "", content([album([11, 10])]), "").previousPathByCurrentPath[first] == nil)
  }

  @Test("pending album alt text is not a media identity")
  func pendingAlbum() {
    let pending: InlineProtocol.Block = .with {
      $0.album = .with { $0.images = [.with { $0.alt = text(0, 3); $0.pending = .init() }] }
    }
    let old = content([pending])
    #expect(reconcile(old, "alt", old, "alt").previousPathByCurrentPath[first] == first)
    #expect(reconcile(old, "alt", content([pending, pending]), "alt").previousPathByCurrentPath[first] == nil)
    #expect(reconcile(old, "alt", old, "new").previousPathByCurrentPath[first] == nil)
  }

  @Test("photo swaps map simultaneously and duplicate photos do not choose an occurrence")
  func photoSwaps() {
    let old = content([image(10), image(20)])
    let result = reconcile(old, "", content([image(20), image(10)]), "")
    #expect(result.previousPathByCurrentPath == [first: second, second: first])
    #expect(result.insertedPaths.isEmpty)
    #expect(result.removedPaths.isEmpty)
    #expect(reconcile(content([image(10), image(10)]), "", content([image(10)]), "")
      .previousPathByCurrentPath.isEmpty)
  }

  @Test("message identity isolates unsaved rows and survives persisted confirmation")
  func messageIdentity() {
    var pending = Message(
      messageId: 0, randomId: 42, fromId: 1, date: Date(timeIntervalSince1970: 1),
      text: "", peerUserId: 2, peerThreadId: nil, chatId: 3
    )
    var other = pending
    other.randomId = 43
    #expect(BlockContentMessageIdentity(message: pending) != BlockContentMessageIdentity(message: other))
    pending.globalId = 100
    var confirmed = pending
    confirmed.randomId = nil
    confirmed.messageId = 200
    #expect(BlockContentMessageIdentity(message: pending) == BlockContentMessageIdentity(message: confirmed))
    pending.globalId = nil
    other = pending
    other.randomId = nil
    other.globalId = 42
    #expect(BlockContentMessageIdentity(message: pending) != BlockContentMessageIdentity(message: other))
    other = pending
    other.chatId = 4
    #expect(BlockContentMessageIdentity(message: pending) != BlockContentMessageIdentity(message: other))
  }

  @Test("canonically equivalent Unicode is not a literal range snapshot")
  func literalSourceIdentity() {
    let spellings = [("\u{e9}x", "e\u{301}x", Int64(1)),
                     ("e\u{301}\u{323}x", "e\u{323}\u{301}x", Int64(2))]
    for (oldSource, newSource, length) in spellings {
      #expect(oldSource == newSource)
      #expect(!oldSource.utf8.elementsEqual(newSource.utf8))
      let blocks = content([disclosure(0, length)])
      var state = BlockContentDisclosureState()
      state.set(true, path: first, content: BlockContentPayload(blocks), source: oldSource)
      #expect(reconcile(blocks, oldSource, blocks, newSource).previousPathByCurrentPath.isEmpty)
      #expect(state.overrides(content: BlockContentPayload(blocks), source: newSource).isEmpty)
    }
  }

  private func reconcile(
    _ previous: InlineProtocol.BlockContent, _ oldSource: String,
    _ current: InlineProtocol.BlockContent, _ newSource: String
  ) -> BlockContentReconciliation {
    BlockContentReconciler.reconcile(
      previous: previous, current: current, previousSource: oldSource, currentSource: newSource
    )
  }

  private func content(_ blocks: [InlineProtocol.Block]) -> InlineProtocol.BlockContent {
    .with { $0.blocks = blocks }
  }

  private func text(_ offset: Int64, _ length: Int64) -> InlineProtocol.BlockText {
    .with { $0.offset = offset; $0.length = length }
  }

  private func disclosure(_ offset: Int64, _ length: Int64, children: [InlineProtocol.Block] = []) -> InlineProtocol.Block {
    .with { $0.disclosure = .with { $0.summary = text(offset, length); $0.children = children } }
  }

  private func table(header: InlineProtocol.BlockText, body: InlineProtocol.BlockText? = nil) -> InlineProtocol.Block {
    .with {
      $0.table = .with {
        $0.alignments = [.left]
        $0.rows = [.with { $0.cells = [header] }]
        if let body { $0.rows.append(.with { $0.cells = [body] }) }
      }
    }
  }

  private func image(_ id: Int64) -> InlineProtocol.Block {
    .with { $0.image = .with { $0.ready = .with { $0.id = id } } }
  }

  private func album(_ ids: [Int64]) -> InlineProtocol.Block {
    .with { $0.album = .with { $0.images = ids.map { image($0).image } } }
  }
}
