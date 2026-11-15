import Foundation
import InlineProtocol

/// Message actions a block draws as its own buttons.
///
/// Agent blocks such as plan proposals, approvals and task suggestions list IDs from
/// `Message.actions` in `action_ids`. A client that draws those blocks shows the buttons
/// inside them and leaves them out of the message's action rows; older clients keep showing
/// them in the rows, where they still work.
public enum BlockInlineActions {
  /// Action IDs drawn inside `blocks`, children included.
  public static func ids(in blocks: [Block]) -> Set<String> {
    var ids: Set<String> = []
    collect(blocks, into: &ids)
    return ids
  }

  /// `actions` keyed by ID, for blocks that look their buttons up.
  public static func byID(_ actions: MessageActions?) -> [String: MessageAction] {
    var byID: [String: MessageAction] = [:]
    for row in actions?.rows ?? [] {
      for action in row.actions where byID[action.actionID] == nil {
        byID[action.actionID] = action
      }
    }
    return byID
  }

  /// The message's action rows a client shows under the message: well-formed actions only,
  /// without `drawnInside`, the ones blocks it actually drew claim as their own buttons.
  /// Rows left empty are dropped.
  ///
  /// Pass what the layout drew, not `ids(in:)`: a block that fell back to text, sits in a
  /// collapsed disclosure, or isn't rendered at all leaves its buttons in the rows.
  public static func renderableRows(for message: Message, drawnInside inside: Set<String>) -> [MessageActionRow] {
    (message.actions?.rows ?? []).compactMap { row in
      let actions = row.actions.filter { action in
        !action.actionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && !action.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && action.action != nil
          && !inside.contains(action.actionID)
      }
      guard !actions.isEmpty else { return nil }
      var next = MessageActionRow()
      next.actions = actions
      return next
    }
  }

  /// `actions` without the ones blocks draw; rows left empty are dropped.
  public static func remainingRows(_ actions: MessageActions?, drawnInside ids: Set<String>) -> [MessageActionRow] {
    (actions?.rows ?? []).compactMap { row in
      var row = row
      row.actions.removeAll { ids.contains($0.actionID) }
      return row.actions.isEmpty ? nil : row
    }
  }

  private static func collect(_ blocks: [Block], into ids: inout Set<String>) {
    for block in blocks {
      switch block.kind {
      case let .planProposal(plan)?:
        ids.formUnion(plan.actionIds)
        collect(plan.children, into: &ids)
      case let .approval(approval)?:
        ids.formUnion(approval.actionIds)
        collect(approval.children, into: &ids)
      case let .review(review)?:
        for finding in review.findings where finding.hasActionID { ids.insert(finding.actionID) }
      case let .taskSuggestion(task)?:
        ids.formUnion(task.actionIds)
      case let .nextStep(step)?:
        ids.formUnion(step.actionIds)
      case let .list(list)?:
        for item in list.items { collect(item.children, into: &ids) }
      case let .quote(quote)?:
        collect(quote.children, into: &ids)
      case let .disclosure(disclosure)?:
        collect(disclosure.children, into: &ids)
      case let .callout(callout)?:
        collect(callout.children, into: &ids)
      default:
        break
      }
    }
  }
}
