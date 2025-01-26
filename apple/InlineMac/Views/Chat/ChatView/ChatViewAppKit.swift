import AppKit
import Combine
import InlineKit
import SwiftUI

class ChatViewAppKit: NSView {
  var peerId: Peer

  private var messageList: MessageListAppKit
  private var compose: ComposeAppKit
  private var viewModel: FullChatViewModel?

  private func createViews() {
    setupView()
  }

  private var cancellables = Set<AnyCancellable>()

  init(peerId: Peer) {
    self.peerId = peerId

    messageList = MessageListAppKit(peerId: peerId)
    compose = ComposeAppKit(peerId: peerId, messageList: messageList)

    super.init(frame: .zero)
    setupView()

    AppSettings.shared.$messageStyle
      .sink { [weak self] _ in
        // A delay so value changes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
          // Bubble vs no bubble requires a lot of resetting

          CacheAttrs.shared.invalidate()
          MessageSizeCalculator.shared.invalidateCache()

          print("message style changed")
          self?.resetViews()
        }
      }
      .store(in: &cancellables)
  }

  private func resetViews() {
    messageList.view.removeFromSuperview()
    compose.removeFromSuperview()

    messageList = MessageListAppKit(peerId: peerId)
    compose = ComposeAppKit(peerId: peerId, messageList: messageList)

    setupView()
    needsLayout = true
    needsLayout = true
    layoutSubtreeIfNeeded()
    if let viewModel {
      compose.update(viewModel: viewModel)
    }
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
