import Auth
import InlineKit
import UIKit

// TODO: extract the content into another view
// TODO: make ComposeEmbedView a skelton for all the embeds

enum EmbedType: String {
  case edit
  case reply
  case forward
}

class ComposeEmbedView: UIView {
  static let height: CGFloat = ComposeEmbedViewContent.height

  var peerId: Peer
  private var messageChatId: Int64
  private var messageId: Int64
  private var mode: ComposeEmbedViewContent.Mode

  lazy var content: ComposeEmbedViewContent = {
    let view = ComposeEmbedViewContent(
      peerId: peerId,
      messageChatId: messageChatId,
      messageId: messageId,
      mode: mode
    )
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  init(peerId: Peer, messageChatId: Int64, messageId: Int64, mode: ComposeEmbedViewContent.Mode) {
    self.peerId = peerId
    self.messageChatId = messageChatId
    self.messageId = messageId
    self.mode = mode

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
      content.topAnchor.constraint(equalTo: topAnchor),
      content.bottomAnchor.constraint(equalTo: bottomAnchor),
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
