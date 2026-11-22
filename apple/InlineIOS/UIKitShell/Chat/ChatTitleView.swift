import Combine
import InlineCompatUI
import InlineKit
import InlineUI
import RealtimeV2
import UIKit

/// Chat navigation title: identity, title and a live subtitle (connection state, typing and other
/// compose activity, local time, bot presence). Tapping opens Chat Info.
///
/// iOS 26+: larger avatar like the SwiftUI toolbar (44pt); 32pt before.
@MainActor
final class ChatTitleView: UIControl {
  var onTap: (() -> Void)?

  private let avatarView = UserAvatarLayerView()
  private let threadIconView = ThreadIconLayerView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private var peer: Peer?
  private weak var viewModel: FullChatViewModel?
  private var cancellables: Set<AnyCancellable> = []
  private var activityToken: CompatObservationToken?

  private var avatarSize: CGFloat {
    if #available(iOS 26.0, *), CompatRuntime.allows(.iOS26) { return 36 }
    return 32
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    titleLabel.font = .preferredFont(forTextStyle: .headline)
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.lineBreakMode = .byTruncatingTail
    subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
    subtitleLabel.adjustsFontForContentSizeCategory = true
    subtitleLabel.textColor = .secondaryLabel
    subtitleLabel.lineBreakMode = .byTruncatingTail

    let identity = UIView()
    identity.translatesAutoresizingMaskIntoConstraints = false
    for view in [avatarView, threadIconView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      identity.addSubview(view)
      view.pinEdges(to: identity)
    }
    NSLayoutConstraint.activate([
      identity.widthAnchor.constraint(equalToConstant: avatarSize),
      identity.heightAnchor.constraint(equalToConstant: avatarSize),
    ])

    let text = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
    text.axis = .vertical
    text.spacing = 0
    let row = UIStackView(arrangedSubviews: [identity, text])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 9
    row.isUserInteractionEnabled = false
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    row.pinEdges(to: self)

    addTarget(self, action: #selector(tapped), for: .touchUpInside)
    isAccessibilityElement = true
    accessibilityTraits = [.header, .button]
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.layoutFittingExpandedSize.width, height: max(avatarSize, 36))
  }

  @objc private func tapped() { onTap?() }

  override var isHighlighted: Bool {
    didSet { alpha = isHighlighted ? 0.6 : 1 }
  }

  func bind(peer: Peer, viewModel: FullChatViewModel) {
    self.peer = peer
    self.viewModel = viewModel
    cancellables = []
    viewModel.chatItemPublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.render() }
      .store(in: &cancellables)
    Api.realtime.stateObject.$displayedConnectionState
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.renderSubtitle() }
      .store(in: &cancellables)
    let activity = ComposeActions.shared.activityState(for: peer)
    activityToken = observe { [weak self, activity] in
      _ = activity.presentation
      self?.renderSubtitle()
    }
    render()
  }

  private func render() {
    guard let peer, let viewModel else { return }
    let title: String
    if case .user = peer {
      title = viewModel.peerUser.map { $0.needsDisplayNameFetch ? "" : $0.displayName } ?? ""
      if let info = viewModel.peerUserInfo {
        avatarView.isHidden = false
        threadIconView.isHidden = true
        avatarView.configure(with: info, size: avatarSize)
      }
    } else if let chat = viewModel.chat {
      title = chat.isReplyThread
        ? ReplyThreadToolbarContextLoader.fallbackTitle(for: chat)
        : (chat.humanReadableTitle ?? "")
      avatarView.isHidden = true
      threadIconView.isHidden = false
      threadIconView.configure(
        ThreadIconDescriptor(chat: chat),
        size: .regular(avatarSize),
        shape: .circle,
        symbolColor: .mutedPrimary
      )
    } else {
      title = ""
    }
    titleLabel.text = title
    renderSubtitle()
  }

  private func renderSubtitle() {
    guard let peer, let viewModel else { return }
    let text: String?
    var isActivity = false
    if let connection = Api.realtime.stateObject.displayedConnectionState {
      text = connection.title.lowercased()
    } else if let presentation = ComposeActions.shared.activityState(for: peer).presentation {
      isActivity = true
      if presentation.action == .typing,
         let typing = ComposeActions.shared.getTypingDisplayText(for: peer, length: .min), !typing.isEmpty
      {
        text = typing
      } else {
        text = presentation.text
      }
    } else if peer.isPrivate, let user = viewModel.peerUserInfo?.user {
      if let timeZone = user.timeZone,
         !TimeZoneFormatter.shared.matchesViewer(timeZoneId: timeZone),
         let local = TimeZoneFormatter.shared.formatTimeZoneInfo(userTimeZoneId: timeZone), !local.isEmpty
      {
        text = local
      } else {
        text = BotOnlineStatus.subtitle(for: user)
      }
    } else {
      text = nil
    }
    subtitleLabel.text = text
    subtitleLabel.textColor = isActivity ? .tintColor : .secondaryLabel
    subtitleLabel.isHidden = text?.isEmpty ?? true
    accessibilityLabel = [titleLabel.text, text].compactMap { $0 }.joined(separator: ", ")
  }
}
