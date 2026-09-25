import Combine
import GRDB
import InlineKit
import Logger
import UIKit

final class PinnedMessageHeaderView: UIView {
  private enum Constants {
    static let horizontalPadding: CGFloat = 8
    static let contentVerticalPadding: CGFloat = 4
    static let backgroundTopInset: CGFloat = 8
    static let backgroundBottomInset: CGFloat = 8
    static let contentSpacing: CGFloat = 8
    static let closeButtonSize: CGFloat = 44
    static let fadeDuration: TimeInterval = 0.2
  }

  private var preferredHeight: CGFloat {
    max(EmbedMessageView.height(for: .replyBubble, compatibleWith: traitCollection), UIFontMetrics(forTextStyle: .body).scaledValue(for: Constants.closeButtonSize, compatibleWith: traitCollection))
      + (Constants.contentVerticalPadding * 2)
      + Constants.backgroundTopInset
      + Constants.backgroundBottomInset
  }

  var onHeightChange: ((CGFloat) -> Void)?
  var onOpenMessage: ((Int64) -> Void)?

  private let peerId: Peer
  private let chatId: Int64
  private let log = Log.scoped("PinnedMessageHeaderView")

  private var pinnedMessageObservation: AnyCancellable?
  private var messageObservation: AnyCancellable?
  private var currentMessageId: Int64?
  private var isVisible = false

  private let backgroundView: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var primaryButton: UIButton = {
    let button = UIButton(type: .system)
    button.adjustsImageSizeForAccessibilityContentSizeCategory = true
    button.translatesAutoresizingMaskIntoConstraints = false
    button.accessibilityLabel = "Open pinned message"
    button.accessibilityHint = "Jumps to the pinned message in this chat"
    button.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)

    if #available(iOS 26.0, *) {
      var configuration = UIButton.Configuration.glass()
      configuration.contentInsets = .zero
      configuration.cornerStyle = .capsule
      button.configuration = configuration
    } else {
      var configuration = UIButton.Configuration.plain()
      configuration.contentInsets = .zero
      button.configuration = configuration
    }
    return button
  }()

  private lazy var fallbackMaterialView: UIVisualEffectView = {
    let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isUserInteractionEnabled = false
    view.layer.cornerCurve = .continuous
    view.layer.masksToBounds = true
    return view
  }()

  private var didStartObservation = false
  private var backgroundViewTopConstraint: NSLayoutConstraint?
  private var backgroundViewBottomConstraint: NSLayoutConstraint?
  private var closeButtonHeightConstraint: NSLayoutConstraint?

  private lazy var embedView: EmbedMessageView = {
    let view = EmbedMessageView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isUserInteractionEnabled = false
    view.accessibilityElementsHidden = true
    view.showsBackground = false
    view.showsLeadingBar = false
    view.textLeadingPadding = Constants.horizontalPadding
    view.textTrailingPadding = Constants.horizontalPadding
    return view
  }()

  private lazy var closeButton: UIButton = {
    let button = UIButton(type: .system)
    button.adjustsImageSizeForAccessibilityContentSizeCategory = true
    let config = UIImage.SymbolConfiguration(textStyle: .footnote).applying(UIImage.SymbolConfiguration(weight: .regular))
    button.setImage(UIImage(systemName: "xmark", withConfiguration: config), for: .normal)
    button.tintColor = .secondaryLabel
    button.accessibilityLabel = "Unpin message"
    button.accessibilityHint = "Removes this message from the pinned header"
    button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
    button.translatesAutoresizingMaskIntoConstraints = false
    return button
  }()

  init(peerId: Peer, chatId: Int64) {
    self.peerId = peerId
    self.chatId = chatId
    super.init(frame: .zero)
    setupViews()
    setupConstraints()
    applyHiddenState()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupViews() {
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = .clear
    isHidden = true
    alpha = 0

    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(backgroundView)

    if #unavailable(iOS 26.0) {
      backgroundView.addSubview(fallbackMaterialView)
      NSLayoutConstraint.activate([
        fallbackMaterialView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor),
        fallbackMaterialView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor),
        fallbackMaterialView.topAnchor.constraint(equalTo: backgroundView.topAnchor),
        fallbackMaterialView.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor),
      ])
    }

    backgroundView.addSubview(primaryButton)
    primaryButton.addSubview(embedView)
    backgroundView.addSubview(closeButton)

    primaryButton.configurationUpdateHandler = { [weak self] button in
      self?.updatePrimaryPressAppearance(isHighlighted: button.isHighlighted)
    }
  }

  private func setupConstraints() {
    backgroundViewTopConstraint = backgroundView.topAnchor.constraint(
      equalTo: topAnchor,
      constant: Constants.backgroundTopInset
    )
    backgroundViewBottomConstraint = backgroundView.bottomAnchor.constraint(
      equalTo: bottomAnchor,
      constant: -Constants.backgroundBottomInset
    )
    closeButtonHeightConstraint = closeButton.heightAnchor.constraint(equalToConstant: Constants.closeButtonSize).scaledForContentSize()

    NSLayoutConstraint.activate([
      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Constants.horizontalPadding),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Constants.horizontalPadding),
      backgroundViewTopConstraint!,
      backgroundViewBottomConstraint!,

      primaryButton.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor),
      primaryButton.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor),
      primaryButton.topAnchor.constraint(equalTo: backgroundView.topAnchor),
      primaryButton.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor),

      embedView.leadingAnchor.constraint(equalTo: primaryButton.leadingAnchor, constant: Constants.horizontalPadding),
      embedView.centerYAnchor.constraint(equalTo: primaryButton.centerYAnchor),

      closeButton.leadingAnchor.constraint(equalTo: embedView.trailingAnchor, constant: Constants.contentSpacing),
      closeButton.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -Constants.horizontalPadding),
      closeButton.centerYAnchor.constraint(equalTo: embedView.centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: Constants.closeButtonSize).scaledForContentSize(),
      closeButtonHeightConstraint!,
    ])
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory, isVisible {
      onHeightChange?(preferredHeight)
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if #unavailable(iOS 26.0) {
      fallbackMaterialView.layer.cornerRadius = fallbackMaterialView.bounds.height / 2
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    startObservingIfNeeded()
  }

  private func updatePrimaryPressAppearance(isHighlighted: Bool) {
    let animations = { [self] in
      embedView.alpha = isHighlighted ? 0.72 : 1
      embedView.transform = UIAccessibility.isReduceMotionEnabled || !isHighlighted
        ? .identity
        : CGAffineTransform(scaleX: 0.985, y: 0.985)

      if #unavailable(iOS 26.0) {
        fallbackMaterialView.alpha = isHighlighted ? 0.72 : 1
      }
    }

    guard window != nil, !UIAccessibility.isReduceMotionEnabled else {
      animations()
      return
    }

    UIView.animate(
      withDuration: 0.12,
      delay: 0,
      options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
      animations: animations
    )
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

  private func setVisible(_ visible: Bool, animate: Bool = true) {
    guard visible != isVisible else { return }
    isVisible = visible

    let canAnimate = animate && window != nil && !UIAccessibility.isReduceMotionEnabled

    if visible {
      isHidden = false
      alpha = canAnimate ? 0 : 1
      backgroundViewTopConstraint?.constant = Constants.backgroundTopInset
      backgroundViewBottomConstraint?.constant = -Constants.backgroundBottomInset
      closeButtonHeightConstraint?.constant = UIFontMetrics(forTextStyle: .body).scaledValue(for: Constants.closeButtonSize, compatibleWith: traitCollection)
      onHeightChange?(preferredHeight)
      superview?.layoutIfNeeded()

      guard canAnimate else { return }
      UIView.animate(
        withDuration: Constants.fadeDuration,
        delay: 0,
        options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
      ) { [weak self] in
        self?.alpha = 1
      }
    } else {
      guard canAnimate else {
        applyHiddenState()
        return
      }

      alpha = 1
      UIView.animate(
        withDuration: Constants.fadeDuration,
        delay: 0,
        options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
      ) { [weak self] in
        self?.alpha = 0
      } completion: { [weak self] _ in
        guard let self, !self.isVisible else { return }
        self.applyHiddenState()
      }
    }
  }

  private func applyHiddenState() {
    isHidden = true
    alpha = 0
    backgroundViewTopConstraint?.constant = 0
    backgroundViewBottomConstraint?.constant = 0
    closeButtonHeightConstraint?.constant = 0
    onHeightChange?(0)
  }

  @objc private func primaryTapped() {
    guard let messageId = currentMessageId else { return }
    onOpenMessage?(messageId)
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

}
