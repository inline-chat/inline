import Auth
import InlineKit
import UIKit

// TODO: extract the content into another view
// TODO: make ComposeEmbedView a skelton for all the embeds

enum EmbedType: String {
  case edit
  case reply
}

class ComposeEmbedView: UIView {
  static let height: CGFloat = 56

  var peerId: Peer
  private var chatId: Int64
  private var messageId: Int64

  lazy var content: ComposeEmbedViewContent = {
    let view = ComposeEmbedViewContent(peerId: peerId, chatId: chatId, messageId: messageId)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  init(peerId: Peer, chatId: Int64, messageId: Int64) {
    self.peerId = peerId
    self.chatId = chatId
    self.messageId = messageId

    super.init(frame: .zero)

    setupViews()
    setupConstraints()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupViews() {
    backgroundColor = .clear
    clipsToBounds = true
    translatesAutoresizingMaskIntoConstraints = false
  }

  private func setupConstraints() {
    addSubview(content)
    NSLayoutConstraint.activate([
      content.trailingAnchor.constraint(equalTo: trailingAnchor),
      content.leadingAnchor.constraint(equalTo: leadingAnchor),
      content.heightAnchor.constraint(equalToConstant: Self.height)
    ])
  }

  private func findComposeView() -> ComposeView? {
    var current: UIView? = self
    while let parent = current?.superview {
      if let chatContainer = parent as? ChatContainerView {
        return chatContainer.composeView
      }
      current = parent
    }
    return nil
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }
}
