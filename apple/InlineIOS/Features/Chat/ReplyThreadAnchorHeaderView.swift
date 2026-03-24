import Combine
import GRDB
import InlineKit
import Logger
import UIKit

final class ReplyThreadAnchorHeaderView: UIView {
  private enum Constants {
    static let horizontalPadding: CGFloat = 8
    static let incomingTrailingPadding: CGFloat = 18
    static let avatarSize: CGFloat = 28
    static let avatarTop: CGFloat = 28
    static let avatarSpacing: CGFloat = 3
    static let nameTop: CGFloat = 9
    static let nameHeight: CGFloat = 16
    static let nameLeading: CGFloat = 9
    static let nonThreadTopPadding: CGFloat = 6
    static let threadBubbleTopPadding: CGFloat = nameTop + nameHeight
    static let placeholderVerticalPadding: CGFloat = 12
    static let placeholderHorizontalPadding: CGFloat = 12
  }

  private struct AnchorReference: Equatable {
    let parentChatId: Int64
    let parentMessageId: Int64
    let parentPeer: Peer?
  }

  var onHeightChange: ((CGFloat) -> Void)?

  private let chatId: Int64
  private let spaceId: Int64
  private let log = Log.scoped("ReplyThreadAnchorHeaderView")

  private var referenceObservation: AnyCancellable?
  private var messageObservation: AnyCancellable?
  private var currentReference: AnchorReference?
  private var didStartObservation = false
  private var currentAnchorMessage: FullMessage?
  private var lastReportedHeight: CGFloat = 0

  private let contentContainer = UIView()
  private let placeholderBackgroundView = UIView()
  private let placeholderLabel = UILabel()
  private let nameLabel = UILabel()

  private var bubbleView: UIMessageView?
  private var avatarView: UserAvatarView?
  private var avatarSpacerView: UIView?

  init(chatId: Int64, spaceId: Int64) {
    self.chatId = chatId
    self.spaceId = spaceId
    super.init(frame: .zero)
    setupViews()
    setupConstraints()
    renderPlaceholder(text: "Loading original message…")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    startObservingIfNeeded()
  }

  private func setupViews() {
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = .clear

    contentContainer.translatesAutoresizingMaskIntoConstraints = false
    addSubview(contentContainer)

    placeholderBackgroundView.translatesAutoresizingMaskIntoConstraints = false
    placeholderBackgroundView.layer.cornerRadius = 14
    placeholderBackgroundView.layer.cornerCurve = .continuous
    placeholderBackgroundView.backgroundColor = UIColor.secondarySystemFill
    placeholderBackgroundView.isHidden = true
    contentContainer.addSubview(placeholderBackgroundView)

    placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
    placeholderLabel.font = .systemFont(ofSize: 14, weight: .medium)
    placeholderLabel.textColor = .secondaryLabel
    placeholderLabel.numberOfLines = 1
    placeholderBackgroundView.addSubview(placeholderLabel)

    nameLabel.translatesAutoresizingMaskIntoConstraints = false
    nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
    nameLabel.textColor = .secondaryLabel
  }

  private func setupConstraints() {
    NSLayoutConstraint.activate([
      contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
      contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
      contentContainer.topAnchor.constraint(equalTo: topAnchor),
      contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

      placeholderBackgroundView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: Constants.horizontalPadding),
      placeholderBackgroundView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -Constants.horizontalPadding),
      placeholderBackgroundView.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: Constants.nonThreadTopPadding),
      placeholderBackgroundView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

      placeholderLabel.leadingAnchor.constraint(equalTo: placeholderBackgroundView.leadingAnchor, constant: Constants.placeholderHorizontalPadding),
      placeholderLabel.trailingAnchor.constraint(equalTo: placeholderBackgroundView.trailingAnchor, constant: -Constants.placeholderHorizontalPadding),
      placeholderLabel.topAnchor.constraint(equalTo: placeholderBackgroundView.topAnchor, constant: Constants.placeholderVerticalPadding),
      placeholderLabel.bottomAnchor.constraint(equalTo: placeholderBackgroundView.bottomAnchor, constant: -Constants.placeholderVerticalPadding),
    ])
  }

  private func startObservingIfNeeded() {
    guard !didStartObservation else { return }
    didStartObservation = true

    AppDatabase.shared.warnIfInMemoryDatabaseForObservation("ReplyThreadAnchorHeaderView.reference")
    referenceObservation = ValueObservation
      .tracking { [chatId] db in
        guard let chat = try Chat.fetchOne(db, id: chatId),
              let parentChatId = chat.parentChatId,
              let parentMessageId = chat.parentMessageId
        else {
          return nil
        }

        let parentPeer: Peer? = if let parentChat = try Chat.fetchOne(db, id: parentChatId) {
          if let peerUserId = parentChat.peerUserId {
            .user(id: peerUserId)
          } else {
            .thread(id: parentChat.id)
          }
        } else {
          nil
        }

        return AnchorReference(
          parentChatId: parentChatId,
          parentMessageId: parentMessageId,
          parentPeer: parentPeer
        )
      }
      .publisher(in: AppDatabase.shared.dbWriter, scheduling: .immediate)
      .receive(on: DispatchQueue.main)
      .sink(
        receiveCompletion: { [weak self] completion in
          self?.log.error("Reply-thread anchor reference observation failed: \(completion)")
        },
        receiveValue: { [weak self] reference in
          self?.updateReference(reference)
        }
      )
  }

  private func updateReference(_ reference: AnchorReference?) {
    guard reference != currentReference else { return }

    currentReference = reference
    currentAnchorMessage = nil
    messageObservation?.cancel()
    messageObservation = nil

    guard let reference else {
      renderPlaceholder(text: "Original message unavailable")
      return
    }

    if let message = loadAnchorMessage(reference: reference) {
      renderMessage(message)
    } else {
      renderPlaceholder(text: "Loading original message…")
      fetchMissingAnchorIfNeeded(reference: reference)
    }

    observeAnchorMessage(reference: reference)
  }

  private func loadAnchorMessage(reference: AnchorReference) -> FullMessage? {
    do {
      return try AppDatabase.shared.dbWriter.read { db in
        try FullMessage.queryRequest()
          .filter(
            Column("messageId") == reference.parentMessageId
              && Column("chatId") == reference.parentChatId
          )
          .fetchOne(db)
      }
    } catch {
      log.error("Failed to read reply-thread anchor", error: error)
      return nil
    }
  }

  private func observeAnchorMessage(reference: AnchorReference) {
    AppDatabase.shared.warnIfInMemoryDatabaseForObservation("ReplyThreadAnchorHeaderView.message")
    messageObservation = ValueObservation
      .tracking { db in
        try FullMessage.queryRequest()
          .filter(
            Column("messageId") == reference.parentMessageId
              && Column("chatId") == reference.parentChatId
          )
          .fetchOne(db)
      }
      .publisher(in: AppDatabase.shared.dbWriter, scheduling: .immediate)
      .receive(on: DispatchQueue.main)
      .sink(
        receiveCompletion: { [weak self] completion in
          self?.log.error("Reply-thread anchor observation failed: \(completion)")
        },
        receiveValue: { [weak self] message in
          guard let self else { return }
          if let message {
            renderMessage(message)
          } else {
            renderPlaceholder(text: "Original message unavailable")
            fetchMissingAnchorIfNeeded(reference: reference)
          }
        }
      )
  }

  private func fetchMissingAnchorIfNeeded(reference: AnchorReference) {
    guard let parentPeer = reference.parentPeer else { return }
    Task {
      await TargetMessagesFetcher.shared.ensureCached(
        peer: parentPeer,
        chatId: reference.parentChatId,
        messageIds: [reference.parentMessageId]
      )
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    reportHeightIfNeeded()
  }

  private func renderMessage(_ message: FullMessage) {
    guard currentAnchorMessage != message else { return }

    currentAnchorMessage = message
    clearRenderedSubviews()
    placeholderBackgroundView.isHidden = true

    let outgoing = message.message.out == true
    let isThreadMessage = message.peerId.isThread
    let showsSenderHeader = isThreadMessage && !outgoing

    let messageView = UIMessageView(fullMessage: message, spaceId: spaceId, showsReplyThreadFooter: false)
    messageView.translatesAutoresizingMaskIntoConstraints = false
    contentContainer.addSubview(messageView)
    bubbleView = messageView

    if showsSenderHeader {
      let avatarOrSpacer: UIView
      if let senderInfo = message.senderInfo {
        let avatar = UserAvatarView()
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.configure(with: senderInfo, size: Constants.avatarSize)
        contentContainer.addSubview(avatar)
        avatarView = avatar
        avatarOrSpacer = avatar
      } else {
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(spacer)
        avatarOrSpacer = spacer
      }

      avatarSpacerView = avatarOrSpacer
      nameLabel.text = message.from?.firstName ?? message.from?.username ?? "User"
      contentContainer.addSubview(nameLabel)

      NSLayoutConstraint.activate([
        avatarOrSpacer.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: Constants.avatarTop),
        avatarOrSpacer.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: Constants.horizontalPadding),
        avatarOrSpacer.widthAnchor.constraint(equalToConstant: Constants.avatarSize),
        avatarOrSpacer.heightAnchor.constraint(equalToConstant: Constants.avatarSize),

        nameLabel.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: Constants.nameTop),
        nameLabel.heightAnchor.constraint(equalToConstant: Constants.nameHeight),
        nameLabel.leadingAnchor.constraint(equalTo: avatarOrSpacer.trailingAnchor, constant: Constants.nameLeading),

        messageView.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: Constants.threadBubbleTopPadding),
        messageView.leadingAnchor.constraint(equalTo: avatarOrSpacer.trailingAnchor, constant: Constants.avatarSpacing),
        messageView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -Constants.incomingTrailingPadding),
        messageView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
      ])
    } else {
      NSLayoutConstraint.activate([
        messageView.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: Constants.nonThreadTopPadding),
        messageView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: Constants.horizontalPadding),
        messageView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -Constants.horizontalPadding),
        messageView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
      ])
    }

    setNeedsLayout()
    layoutIfNeeded()
    reportHeightIfNeeded(force: true)
  }

  private func renderPlaceholder(text: String) {
    currentAnchorMessage = nil
    clearRenderedSubviews()
    placeholderLabel.text = text
    placeholderBackgroundView.isHidden = false
    setNeedsLayout()
    layoutIfNeeded()
    reportHeightIfNeeded(force: true)
  }

  private func clearRenderedSubviews() {
    bubbleView?.removeFromSuperview()
    bubbleView = nil
    avatarView?.removeFromSuperview()
    avatarView = nil
    avatarSpacerView?.removeFromSuperview()
    avatarSpacerView = nil
    nameLabel.removeFromSuperview()
  }

  private func reportHeightIfNeeded(force: Bool = false) {
    let targetWidth = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
    guard targetWidth > 0 else { return }

    let measuredHeight = ceil(
      systemLayoutSizeFitting(
        CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height),
        withHorizontalFittingPriority: .required,
        verticalFittingPriority: .fittingSizeLevel
      ).height
    )

    guard force || abs(measuredHeight - lastReportedHeight) > 0.5 else { return }
    lastReportedHeight = measuredHeight
    onHeightChange?(measuredHeight)
  }
}
