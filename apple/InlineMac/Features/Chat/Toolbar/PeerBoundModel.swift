import Combine
import Foundation
import InlineKit

// A stable chat route keeps its toolbar items across chat switches: giving them a per-chat `.id`
// would make NSToolbar rebuild every item's view on each switch. Views that own a per-chat model
// hold it through one of these instead, and get the model for the peer they are rendering.
//
// The swap happens while the view reads its model in `body`, so the first frame of the new chat
// already shows the new chat's model. Nothing is published during the swap; the outgoing model
// lives until the next run loop turn so its teardown stays out of the switch's frame.
//
// Long-lived closures (registered commands, callbacks kept by other objects) must read `current`
// instead of calling `model(for:)` with the peer they captured, which may be an older chat.

/// Holds the current chat's `ObservableObject` model and forwards its changes to the view.
@MainActor
final class PeerBoundObject<Model: ObservableObject>: ObservableObject
  where Model.ObjectWillChangePublisher == ObservableObjectPublisher
{
  private(set) var peer: Peer
  private(set) var current: Model
  private let release: (Model) -> Void
  private var forwarding: AnyCancellable?

  init(peer: Peer, model: Model, release: @escaping (Model) -> Void = { _ in }) {
    self.peer = peer
    current = model
    self.release = release
    forwardChanges()
  }

  func model(for peer: Peer, make: (Peer) -> Model) -> Model {
    guard self.peer != peer else { return current }
    let outgoing = current
    self.peer = peer
    current = make(peer)
    forwardChanges()
    let release = release
    DispatchQueue.main.async {
      release(outgoing)
    }
    return current
  }

  private func forwardChanges() {
    forwarding = current.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
  }
}

/// Holds the current chat's `@Observable` model. Held in `@State`; it publishes nothing itself,
/// since the view reading it is already re-rendering for the new peer and then tracks the new
/// model's properties.
///
/// The model is made on first read, not in `init`: `State(initialValue:)` evaluates its argument on
/// every init of the owning view (every parent body pass), so an eagerly made model would be built
/// and thrown away on each pass, with whatever reads and observations it starts.
@MainActor
final class PeerBoundBox<Model: AnyObject> {
  private(set) var peer: Peer?
  private(set) var current: Model?
  private let release: (Model) -> Void

  init(release: @escaping (Model) -> Void = { _ in }) {
    self.release = release
  }

  func model(for peer: Peer, make: (Peer) -> Model) -> Model {
    if let current, self.peer == peer { return current }
    let outgoing = current
    let model = make(peer)
    self.peer = peer
    current = model
    if let outgoing {
      let release = release
      DispatchQueue.main.async {
        release(outgoing)
      }
    }
    return model
  }
}
