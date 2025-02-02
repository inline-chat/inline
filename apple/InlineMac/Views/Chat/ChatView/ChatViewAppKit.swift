import AppKit
import Combine
import InlineKit
import SwiftUI

class ChatViewAppKit: NSView {
  var peerId: Peer

  private var messageList: MessageListAppKit
  private var compose: ComposeAppKit
  private var viewModel: FullChatViewModel?
  private var chat: Chat? // TODO: get rid of ?

  private func createViews() {
    setupView()
  }

  init(peerId: Peer) {
    self.peerId = peerId

    chat = try? Chat.getByPeerId(peerId: peerId)

    messageList = MessageListAppKit(peerId: peerId)
    compose = ComposeAppKit(peerId: peerId, messageList: messageList, chat: chat)

    super.init(frame: .zero)
    setupView()
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private var composeView: NSView {
    compose
  }

  private var messageListView: NSView {
    messageList.view
  }

  private func setupView() {
    // Performance
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    layer?.drawsAsynchronously = true

    // Enable Auto Layout for the main view
    translatesAutoresizingMaskIntoConstraints = false
    messageListView.translatesAutoresizingMaskIntoConstraints = false
    composeView.translatesAutoresizingMaskIntoConstraints = false

    addSubview(messageListView)
    addSubview(composeView)

    // initial height sync with msg list
    compose.updateHeight()

    NSLayoutConstraint.activate([
      // messageList
      messageListView.topAnchor.constraint(equalTo: topAnchor),
      messageListView.leadingAnchor.constraint(equalTo: leadingAnchor),
      messageListView.trailingAnchor.constraint(equalTo: trailingAnchor),
      messageListView.bottomAnchor.constraint(equalTo: bottomAnchor),

      // compose
      composeView.bottomAnchor.constraint(equalTo: bottomAnchor),
      composeView.leadingAnchor.constraint(equalTo: leadingAnchor),
      composeView.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
  }

  func update(messages: [FullMessage]) {}

  func update(viewModel: FullChatViewModel) {
    self.viewModel = viewModel
    // Update compose
    compose.update(viewModel: viewModel)
  }
}
