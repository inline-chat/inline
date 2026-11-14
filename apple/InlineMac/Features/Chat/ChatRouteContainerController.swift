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

    releaseAfterSwitch(outgoing)
  }

  func dispose() {
    guard !isDisposed else { return }
    isDisposed = true
    let outgoing = detachCurrentChat()
    peer = nil
    releaseAfterSwitch(outgoing)
  }

  /// Ends the current chat while its view is still in the window, so it records the reading place
  /// the user saw, then takes it out of the hierarchy.
  private func detachCurrentChat() -> ChatViewAppKit? {
    guard let current = chat else { return nil }
    chat = nil
    current.dispose()
    NSLayoutConstraint.deactivate(chatConstraints)
    chatConstraints = []
    current.view.removeFromSuperview()
    current.removeFromParent()
    return current
  }

  /// Tearing down a chat's view tree costs tens of milliseconds; keep the outgoing chat alive until
  /// the next run loop turn so its release lands after the incoming chat's first frame.
  private func releaseAfterSwitch(_ outgoing: ChatViewAppKit?) {
    guard let outgoing else { return }
    DispatchQueue.main.async {
      withExtendedLifetime(outgoing) {}
    }
  }
}
