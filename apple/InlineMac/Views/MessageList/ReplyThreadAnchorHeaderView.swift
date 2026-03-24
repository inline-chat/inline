import AppKit
import Combine
import GRDB
import InlineKit
import Logger

private let replyThreadHeaderCornerRadius: CGFloat = 14

final class ReplyThreadAnchorHeaderView: NSView {
  private enum Constants {
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 16
    static let fadeDuration: TimeInterval = 0.2
  }

  static let preferredHeight: CGFloat = EmbedMessageView.height + (Constants.verticalPadding * 2)

  private let parentChatId: Int64?
  private let parentMessageId: Int64?
  private let log = Log.scoped("ReplyThreadAnchorHeaderView")

  var onHeightChange: ((CGFloat) -> Void)?

  private var parentChatObservation: AnyCancellable?
  private var anchorObservation: AnyCancellable?
  private var parentPeer: Peer?
  private var didStartObservation = false
  private var hasRequestedFetch = false
  private var isVisible = false

  private let backgroundView: NSVisualEffectView = {
    let view = NSVisualEffectView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.material = .hudWindow
    view.blendingMode = .withinWindow
    view.state = .active
    view.wantsLayer = true
    view.layer?.cornerRadius = replyThreadHeaderCornerRadius
    view.layer?.masksToBounds = true
    return view
  }()

  private lazy var embedView: EmbedMessageView = {
    let view = EmbedMessageView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    view.showsBackground = false
    view.showsLeadingBar = false
    view.textLeadingPadding = Constants.horizontalPadding
    view.textTrailingPadding = Constants.horizontalPadding
    return view
  }()

  private var backgroundViewTopConstraint: NSLayoutConstraint?
  private var backgroundViewBottomConstraint: NSLayoutConstraint?

  init(parentChatId: Int64?, parentMessageId: Int64?) {
    self.parentChatId = parentChatId
    self.parentMessageId = parentMessageId
    super.init(frame: .zero)
    setupView()
    setupConstraints()
    applyHiddenState()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    addSubview(backgroundView)
    backgroundView.addSubview(embedView)
  }

  private func setupConstraints() {
    backgroundViewTopConstraint = backgroundView.topAnchor.constraint(equalTo: topAnchor, constant: Constants.verticalPadding)
    backgroundViewBottomConstraint = backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Constants.verticalPadding)

    NSLayoutConstraint.activate([
      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Constants.horizontalPadding),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Constants.horizontalPadding),
      backgroundViewTopConstraint!,
      backgroundViewBottomConstraint!,

      embedView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: Constants.horizontalPadding),
      embedView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -Constants.horizontalPadding),
      embedView.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),
    ])
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    startObservingIfNeeded()
  }

  private func startObservingIfNeeded() {
    guard !didStartObservation else { return }
    didStartObservation = true

    guard let parentChatId, let parentMessageId else { return }

    setVisible(true, animate: false)
    embedView.showNotLoaded(
      kind: .replyInMessage,
      senderName: "Reply thread",
      messageText: "Loading original message…"
    )

    AppDatabase.shared.warnIfInMemoryDatabaseForObservation("ReplyThreadAnchorHeaderView.parentChat")
    parentChatObservation = ValueObservation
      .tracking { db in
        try Chat.fetchOne(db, id: parentChatId)
      }
      .publisher(in: AppDatabase.shared.dbWriter, scheduling: .immediate)
      .receive(on: DispatchQueue.main)
      .sink(
        receiveCompletion: { [weak self] completion in
          self?.log.error("Reply thread parent chat observation failed: \(completion)")
        },
        receiveValue: { [weak self] chat in
          self?.parentPeer = chat?.peerId.toPeer()
          self?.requestFetchIfNeeded()
        }
      )

    AppDatabase.shared.warnIfInMemoryDatabaseForObservation("ReplyThreadAnchorHeaderView.anchorMessage")
    anchorObservation = ValueObservation
      .tracking { db in
        try FullMessage.queryRequest()
          .filter(
            Column("messageId") == parentMessageId && Column("chatId") == parentChatId
          )
          .fetchOne(db)
      }
      .publisher(in: AppDatabase.shared.dbWriter, scheduling: .immediate)
      .receive(on: DispatchQueue.main)
      .sink(
        receiveCompletion: { [weak self] completion in
          self?.log.error("Reply thread anchor observation failed: \(completion)")
        },
        receiveValue: { [weak self] message in
          self?.updateAnchorMessage(message)
        }
      )
  }

  private func updateAnchorMessage(_ message: FullMessage?) {
    guard parentChatId != nil, parentMessageId != nil else {
      setVisible(false, animate: false)
      return
    }

    setVisible(true)

    if let message {
      embedView.configure(
        fullMessage: message,
        kind: .replyInMessage,
        outgoing: false,
        isOnlyEmoji: false,
        style: .replyBubble
      )
      return
    }

    embedView.showNotLoaded(
      kind: .replyInMessage,
      senderName: "Reply thread",
      messageText: "Original message unavailable"
    )
    requestFetchIfNeeded()
  }

  private func requestFetchIfNeeded() {
    guard !hasRequestedFetch else { return }
    guard let parentChatId, let parentMessageId, let parentPeer else { return }
    hasRequestedFetch = true

    Task {
      await TargetMessagesFetcher.shared.ensureCached(
        peer: parentPeer,
        chatId: parentChatId,
        messageIds: [parentMessageId]
      )
    }
  }

  private func setVisible(_ visible: Bool, animate: Bool = true) {
    guard visible != isVisible else { return }
    isVisible = visible

    let canAnimate = animate && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    if visible {
      isHidden = false
      alphaValue = canAnimate ? 0 : 1
      backgroundViewTopConstraint?.constant = Constants.verticalPadding
      backgroundViewBottomConstraint?.constant = -Constants.verticalPadding
      embedView.setCollapsed(false)
      onHeightChange?(Self.preferredHeight)
      superview?.layoutSubtreeIfNeeded()

      guard canAnimate else { return }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = Constants.fadeDuration
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        context.allowsImplicitAnimation = true
        animator().alphaValue = 1
      }
    } else {
      guard canAnimate else {
        applyHiddenState()
        return
      }

      alphaValue = 1
      NSAnimationContext.runAnimationGroup { context in
        context.duration = Constants.fadeDuration
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        context.allowsImplicitAnimation = true
        animator().alphaValue = 0
      } completionHandler: { [weak self] in
        guard let self, !self.isVisible else { return }
        self.applyHiddenState()
      }
    }
  }

  private func applyHiddenState() {
    isHidden = true
    alphaValue = 0
    backgroundViewTopConstraint?.constant = 0
    backgroundViewBottomConstraint?.constant = 0
    embedView.setCollapsed(true)
    onHeightChange?(0)
  }
}
