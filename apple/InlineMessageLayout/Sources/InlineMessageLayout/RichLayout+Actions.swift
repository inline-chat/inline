import CoreGraphics

public extension RichLayout {
  /// Of the message actions blocks claim, the ones this layout draws. `owners` maps each
  /// claimed action to the path of the innermost block that claimed it.
  ///
  /// A block a collapsed plan cuts off isn't placed, and a container card the cut shortens
  /// hides the buttons below the cut; their actions are left out, so the host keeps them in
  /// the message's action rows. A layout past the limits is nil and draws none.
  func drawnActions(_ owners: [String: RichPath]) -> Set<String> {
    var placed: [RichPath: Placed] = [:]
    for node in nodes where placed[node.path] == nil {
      placed[node.path] = node
    }
    var drawn: Set<String> = []
    for (id, owner) in owners {
      guard let node = placed[owner] else { continue }
      if case let .card(card) = node.node {
        let hidden = card.parts.contains { $0.tap == .action(id: id) && $0.frame.maxY > node.frame.height + 0.5 }
        if hidden { continue }
      }
      drawn.insert(id)
    }
    return drawn
  }
}
