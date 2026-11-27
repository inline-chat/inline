import AppKit
import InlineKit

/// Hosts the chat route's `ChatViewAppKit` and swaps it in place when the route moves to another chat.
///
/// SwiftUI keeps this controller (and its view) for as long as the window shows chats, so switching
/// chats never makes SwiftUI remove and insert a platform view. That insertion is what forced the
/// whole new chat to lay out inside SwiftUI's render pass, re-hosted its Auto Layout engine, and
/// rebuilt the window's key-view loop on every switch.
final class ChatRouteContainerController: NSViewController {
  private(set) var peer: Peer?
  private var chat: ChatViewAppKit?
  private var chatConstraints: [NSLayoutConstraint] = []
  private var isDisposed = false

  override func loadView() {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    self.view = view
  }

  /// Shows `peer`, building its chat view only when the peer changes.
  func show(peer: Peer, make: () -> ChatViewAppKit) {
    guard !isDisposed, self.peer != peer else { return }
    self.peer = peer

    let outgoing = detachCurrentChat()
    let incoming = make()
    addChild(incoming)
    view.addSubview(incoming.view)
    incoming.view.translatesAutoresizingMaskIntoConstraints = false
    chatConstraints = [
      incoming.view.topAnchor.constraint(equalTo: view.topAnchor),
      incoming.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      incoming.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      incoming.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ]
    NSLayoutConstraint.activate(chatConstraints)
    chat = incoming

    releaseAfterSwitch(outgoing, incoming: incoming)
  }

  func dispose() {
    guard !isDisposed else { return }
    isDisposed = true
    let outgoing = detachCurrentChat()
    peer = nil
    releaseAfterSwitch(outgoing)
  }

  /// Ends the current chat while its view is still in the window, so it records the reading place
  /// the user saw. Its view stays in the hierarchy, transparent, until `releaseAfterSwitch` takes it
  /// out: leaving the window tells every view in the chat (about 7 ms a switch in the timeline
  /// journey), which held up the incoming chat's first frame.
  private func detachCurrentChat() -> ChatViewAppKit? {
    guard let current = chat else { return nil }
    chat = nil
    // Keys must not go on reaching the outgoing chat (its composer) while it waits out of sight.
    if let window = current.view.window, let responder = window.firstResponder as? NSView,
       responder.isDescendant(of: current.view)
    {
      window.makeFirstResponder(nil)
    }
    current.dispose(removingViews: false)
    NSLayoutConstraint.deactivate(chatConstraints)
    chatConstraints = []
    current.view.alphaValue = 0
    current.removeFromParent()
    return current
  }

  /// Tearing down a chat's view tree costs tens of milliseconds; the outgoing chat leaves the window
  /// once the incoming chat's first messages are on screen (their frame committed; the switch runs in
  /// SwiftUI's update, the list places rows in a later layout), and is released a second later. That
  /// second also removes it when the incoming chat shows none (switched away at once, no Nav3
  /// signpost); removing twice is harmless.
  private func releaseAfterSwitch(_ outgoing: ChatViewAppKit?, incoming: ChatViewAppKit? = nil) {
    guard let outgoing else { return }
    // Weak here: work a chat never runs must not keep the outgoing one alive. The fallback holds
    // it and releases it, after the incoming chat's first frame either way.
    let remove: () -> Void = { [weak outgoing] in
      guard let outgoing else { return }
      outgoing.view.removeFromSuperview()
    }
    if let incoming {
      incoming.afterFirstMessages(remove)
    } else if let nav3 = outgoing.dependencies.nav3 {
      // A route replaced by another chat's route disposes this container: the next chat's first
      // messages, whichever chat it is.
      nav3.afterFirstMessages(peer: nil, remove)
    } else {
      DispatchQueue.main.async { outgoing.view.removeFromSuperview() }
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { outgoing.view.removeFromSuperview() }
  }
}
