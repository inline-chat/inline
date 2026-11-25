import Foundation
import InlineProtocol
import Testing
@testable import InlineKit

@Suite("Block decision note")
struct BlockDecisionNoteTests {
  private let note = BlockText.with {
    $0.offset = 40
    $0.length = 20
  }

  private func footer(_ text: BlockText) -> Block {
    .with { $0.footer = text }
  }

  @Test("A decided card's footer is its outcome")
  func decided() {
    let approval: [Block] = [.with { $0.approval = .with { $0.state = .accepted } }, footer(note)]
    #expect(BlockDecisionNote.footer(after: 0, in: approval) == note)
    let plan: [Block] = [.with { $0.planProposal = .with { $0.state = .declined } }, footer(note)]
    #expect(BlockDecisionNote.footer(after: 0, in: plan) == note)
  }

  @Test("A pending card, another kind, or a gap keeps the footer as text")
  func notFolded() {
    let pending: [Block] = [.with { $0.approval = .with { $0.state = .pending } }, footer(note)]
    #expect(BlockDecisionNote.footer(after: 0, in: pending) == nil)
    let paragraph: [Block] = [.with { $0.paragraph = note }, footer(note)]
    #expect(BlockDecisionNote.footer(after: 0, in: paragraph) == nil)
    let apart: [Block] = [
      .with { $0.approval = .with { $0.state = .accepted } },
      .with { $0.paragraph = note },
      footer(note),
    ]
    #expect(BlockDecisionNote.footer(after: 0, in: apart) == nil)
    let last: [Block] = [.with { $0.approval = .with { $0.state = .accepted } }]
    #expect(BlockDecisionNote.footer(after: 0, in: last) == nil)
    let empty: [Block] = [.with { $0.approval = .with { $0.state = .accepted } }, footer(.init())]
    #expect(BlockDecisionNote.footer(after: 0, in: empty) == nil)
  }
}
