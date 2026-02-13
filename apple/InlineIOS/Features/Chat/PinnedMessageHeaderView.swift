import Combine
import GRDB
import InlineKit
import Logger
import SwiftUI
import UIKit

final class PinnedMessageHeaderView: UIView, UIGestureRecognizerDelegate {
  private enum Constants {
    static let horizontalPadding: CGFloat = 6
    static let verticalPadding: CGFloat = 10
    static let contentSpacing: CGFloat = 6
    static let closeButtonSize: CGFloat = 32
  }

  static let preferredHeight: CGFloat = EmbedMessageView.height + (Constants.verticalPadding * 2)
  private static let backgroundCornerRadius: CGFloat = 14

  var onHeightChange: ((CGFloat) -> Void)?

  private let peerId: Peer
  private let chatId: Int64
  private let log = Log.scoped("PinnedMessageHeaderView")

  private var pinnedMessageObservation: AnyCancellable?
  private var messageObservation: AnyCancellable?
  private var currentMessageId: Int64?

  private let backgroundView: UIView
  private let backgroundContentView: UIView
  private var didStartObservation = false

  private lazy var embedView: EmbedMessageView = {
    let view = EmbedMessageView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.showsBackground = false
    view.showsLeadingBar = false
    view.textLeadingPadding = Constants.horizontalPadding
    view.textTrailingPadding = Constants.horizontalPadding
    return view
  }()

  private lazy var closeButton: UIButton = {
    let button = UIButton(type: .system)
    let config = UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)
    button.setImage(UIImage(systemName: "xmark", withConfiguration: config), for: .normal)
    button.tintColor = .secondaryLabel
    button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
    button.translatesAutoresizingMaskIntoConstraints = false
    return button
  }()

  init(peerId: Peer, chatId: Int64) {
    self.peerId = peerId
    self.chatId = chatId
    if #available(iOS 26.0, *) {
      let glassView = PinnedMessageGlassBackgroundView(cornerRadius: Self.backgroundCornerRadius)
      backgroundView = glassView
      backgroundContentView = glassView
    } else {
      let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
      blurView.layer.cornerRadius = Self.backgroundCornerRadius
      blurView.layer.masksToBounds = true
      backgroundView = blurView
      backgroundContentView = blurView.contentView
    }
    super.init(frame: .zero)
    setupViews()
    setupConstraints()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupViews() {
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = .clear
    isHidden = true

    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(backgroundView)
    backgroundContentView.addSubview(embedView)
    backgroundContentView.addSubview(closeButton)

    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    tapGesture.delegate = self
    addGestureRecognizer(tapGesture)
  }

  private func setupConstraints() {
    NSLayoutConstraint.activate([
      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Constants.horizontalPadding),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Constants.horizontalPadding),
      backgroundView.topAnchor.constraint(equalTo: topAnchor, constant: Constants.verticalPadding),
      backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Constants.verticalPadding),

      embedView.leadingAnchor.constraint(equalTo: backgroundContentView.leadingAnchor, constant: Constants.horizontalPadding),
      embedView.centerYAnchor.constraint(equalTo: backgroundContentView.centerYAnchor),
      embedView.heightAnchor.constraint(equalToConstant: EmbedMessageView.height),

      closeButton.leadingAnchor.constraint(equalTo: embedView.trailingAnchor, constant: Constants.contentSpacing),
      closeButton.trailingAnchor.constraint(equalTo: backgroundContentView.trailingAnchor, constant: -Constants.horizontalPadding),
      closeButton.centerYAnchor.constraint(equalTo: embedView.centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: Constants.closeButtonSize),
      closeButton.heightAnchor.constraint(equalToConstant: Constants.closeButtonSize),
    ])
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    startObservingIfNeeded()
  }

  private func startObservingIfNeeded() {
    guard !didStartObservation else { return }
    didStartObservation = true

    do {
      let pinned = try AppDatabase.shared.dbWriter.read { db in
        try PinnedMessage
          .filter(Column("chatId") == chatId)
          .order(PinnedMessage.Columns.position.asc)
          .fetchOne(db)
      }
      updatePinnedMessageId(pinned?.messageId)
    } catch {
      log.error("Failed to read pinned message state", error: error)
    }

    observePinnedMessages()
  }

  private func observePinnedMessages() {
    AppDatabase.shared.warnIfInMemoryDatabaseForObservation("PinnedMessageHeaderView.pinnedMessage")
    pinnedMessageObservation = ValueObservation
      .tracking { [chatId] db in
        try PinnedMessage
          .filter(Column("chatId") == chatId)
          .order(PinnedMessage.Columns.position.asc)
          .fetchOne(db)
      }
      .publisher(in: AppDatabase.shared.dbWriter, scheduling: .immediate)
      .receive(on: DispatchQueue.main)
      .sink(
        receiveCompletion: { [weak self] completion in
          self?.log.error("Pinned message observation failed: \(completion)")
        },
        receiveValue: { [weak self] pinned in
          self?.updatePinnedMessageId(pinned?.messageId)
        }
      )
  }

  private func updatePinnedMessageId(_ messageId: Int64?) {
    guard messageId != currentMessageId else { return }

    currentMessageId = messageId
    messageObservation?.cancel()
    messageObservation = nil

    if let messageId {
      setVisible(true)
      if let message = loadPinnedMessage(messageId: messageId) {
        embedView.configure(
          fullMessage: message,
          kind: .pinnedInHeader,
          outgoing: false,
          isOnlyEmoji: false,
          style: .replyBubble
        )
      } else {
        embedView.showNotLoaded(
          kind: .pinnedInHeader,
          outgoing: false,
          isOnlyEmoji: false,
          style: .replyBubble,
          messageText: "Pinned message unavailable"
        )
        Task {
          await TargetMessagesFetcher.shared.ensureCached(peer: peerId, chatId: chatId, messageIds: [messageId])
        }
      }
      observePinnedMessageContent(messageId: messageId)
    } else {
      setVisible(false)
    }
  }

  private func loadPinnedMessage(messageId: Int64) -> FullMessage? {
    do {
      return try AppDatabase.shared.dbWriter.read { db in
        try FullMessage.queryRequest()
          .filter(
            Column("messageId") == messageId && Column("chatId") == chatId
          )
          .fetchOne(db)
      }
    } catch {
      log.error("Failed to read pinned message state", error: error)
      return nil
    }
  }

  private func observePinnedMessageContent(messageId: Int64) {
    AppDatabase.shared.warnIfInMemoryDatabaseForObservation("PinnedMessageHeaderView.pinnedMessageContent")
    messageObservation = ValueObservation
      .tracking { [chatId] db in
        try FullMessage.queryRequest()
          .filter(
            Column("messageId") == messageId && Column("chatId") == chatId
          )
          .fetchOne(db)
      }
      .publisher(in: AppDatabase.shared.dbWriter, scheduling: .immediate)
      .receive(on: DispatchQueue.main)
      .sink(
        receiveCompletion: { [weak self] completion in
          self?.log.error("Pinned message fetch failed: \(completion)")
        },
        receiveValue: { [weak self] message in
          guard let self else { return }
          if let message {
            embedView.configure(
              fullMessage: message,
              kind: .pinnedInHeader,
              outgoing: false,
              isOnlyEmoji: false,
              style: .replyBubble
            )
          } else {
            embedView.showNotLoaded(
              kind: .pinnedInHeader,
              outgoing: false,
              isOnlyEmoji: false,
              style: .replyBubble,
              messageText: "Pinned message unavailable"
            )
          }
        }
      )
  }

  private func setVisible(_ visible: Bool) {
    isHidden = !visible
    onHeightChange?(visible ? Self.preferredHeight : 0)
  }

  @objc private func handleTap() {
    guard let messageId = currentMessageId else { return }
    NotificationCenter.default.post(
      name: Notification.Name("ScrollToRepliedMessage"),
      object: nil,
      userInfo: [
        "repliedToMessageId": messageId,
        "chatId": chatId,
      ]
    )
  }

  @objc private func closeTapped() {
    guard let messageId = currentMessageId else { return }
    Task { @MainActor in
      do {
        _ = try await Api.realtime.send(.pinMessage(peer: peerId, messageId: messageId, unpin: true))
      } catch {
        Log.shared.error("Failed to unpin message", error: error)
      }
    }
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    if let touchedView = touch.view, touchedView.isDescendant(of: closeButton) {
      return false
    }
    return true
  }
}

@available(iOS 26.0, *)
private final class PinnedMessageGlassBackgroundView: UIView {
  private let hostingController: UIHostingController<PinnedMessageGlassView>

  init(cornerRadius: CGFloat) {
    hostingController = UIHostingController(rootView: PinnedMessageGlassView(cornerRadius: cornerRadius))
    super.init(frame: .zero)

    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    hostingController.view.backgroundColor = .clear
    hostingController.view.isUserInteractionEnabled = false

    addSubview(hostingController.view)
    NSLayoutConstraint.activate([
      hostingController.view.leadingAnchor.constraint(equalTo: leadingAnchor),
      hostingController.view.trailingAnchor.constraint(equalTo: trailingAnchor),
      hostingController.view.topAnchor.constraint(equalTo: topAnchor),
      hostingController.view.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

@available(iOS 26.0, *)
private struct PinnedMessageGlassView: View {
  let cornerRadius: CGFloat

  var body: some View {
    Color.clear
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
      .allowsHitTesting(false)
  }
}
