import Foundation
import InlineProtocol

/// A decided card's outcome in words ("Yes, and don't ask again for git (answered by Mo)").
///
/// Bridges write it as a footer right after the card, for apps that read only the text.
/// Apps that draw the card show it where the buttons were and leave the footer out, so a
/// decided card says once what was chosen and by whom (Mo, 2026-11-25).
public enum BlockDecisionNote {
  /// The outcome footer that follows the decided approval or plan at `index`, if any.
  public static func footer(after index: Int, in blocks: [Block]) -> BlockText? {
    let next = index + 1
    guard blocks.indices.contains(index), blocks.indices.contains(next),
          isDecidedCard(blocks[index]),
          case let .footer(text)? = blocks[next].kind,
          text.length > 0
    else { return nil }
    return text
  }

  private static func isDecidedCard(_ block: Block) -> Bool {
    let state: BlockDecisionState
    switch block.kind {
    case let .approval(approval)?: state = approval.state
    case let .planProposal(plan)?: state = plan.state
    default: return false
    }
    switch state {
    case .accepted, .declined, .expired, .superseded: return true
    case .unspecified, .pending, .UNRECOGNIZED: return false
    }
  }
}
