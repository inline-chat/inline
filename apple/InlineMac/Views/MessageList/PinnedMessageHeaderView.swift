import AppKit
import Combine
import GRDB
import InlineKit
import Logger

final class PinnedMessageHeaderView: NSView {
  static let preferredHeight: CGFloat = Theme.embeddedMessageHeight + 32

  private let peerId: Peer
  private let chatId: Int64
  private let dependencies: AppDependencies
  private let log = Log.scoped("PinnedMessageHeaderView")

  var onHeightChange: ((CGFloat) -> Void)?

  private var pinnedMessageObservation: AnyCancellable?
  private var messageObservation: AnyCancellable?
  private var currentMessageId: Int64?

  private lazy var embedView: EmbeddedMessageView = {
    let view = EmbeddedMessageView(style: .colored)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.showsBackground = false
    view.showsLeadingBar = false
    view.textLeadingPadding = 8
    view.textTrailingPadding = 8
    return view
  }()

  private lazy var glassView: NSVisualEffectView = {
    let view = NSVisualEffectView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.material = .hudWindow
    view.blendingMode = .withinWindow
    view.state = .active
    view.wantsLayer = true
    view.layer?.cornerRadius = 10
    view.layer?.masksToBounds = true
    view.layer?.borderWidth = 0
    view.layer?.borderColor = nil
    return view
  }()

  private lazy var closeButton: NSButton = {
    let button = NSButton()
    button.translatesAutoresizingMaskIntoConstraints = false
    button.isBordered = false
    button.bezelStyle = .inline
    button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Unpin")
    button.contentTintColor = .secondaryLabelColor
    button.target = self
    button.action = #selector(unpinTapped)
    button.toolTip = "Unpin"
    return button
  }()

  private var glassViewTopConstraint: NSLayoutConstraint?
  private var glassViewBottomConstraint: NSLayoutConstraint?
  private var closeButtonHeightConstraint: NSLayoutConstraint?

  init(dependencies: AppDependencies, peerId: Peer, chatId: Int64) {
    self.dependencies = dependencies
    self.peerId = peerId
    self.chatId = chatId
    super.init(frame: .zero)
    setupView()
    setupConstraints()
    setVisible(false)
    observePinnedMessages()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true

    addSubview(glassView)
    glassView.addSubview(embedView)
    glassView.addSubview(closeButton)
    isHidden = true
  }

  private func setupConstraints() {
    glassViewTopConstraint = glassView.topAnchor.constraint(equalTo: topAnchor, constant: 12)
    glassViewBottomConstraint = glassView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
    closeButtonHeightConstraint = closeButton.heightAnchor.constraint(equalToConstant: 24)

    NSLayoutConstraint.activate([
      glassView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      glassView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      glassViewTopConstraint!,
      glassViewBottomConstraint!,

      embedView.leadingAnchor.constraint(equalTo: glassView.leadingAnchor, constant: 6),
      embedView.centerYAnchor.constraint(equalTo: glassView.centerYAnchor),
      closeButton.leadingAnchor.constraint(equalTo: embedView.trailingAnchor, constant: 8),
      closeButton.trailingAnchor.constraint(equalTo: glassView.trailingAnchor, constant: -8),
      closeButton.centerYAnchor.constraint(equalTo: embedView.centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: 24),
      closeButtonHeightConstraint!,
    ])
  }

  private func observePinnedMessages() {
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
      embedView.showNotLoaded(kind: .pinnedInHeader, messageText: "Pinned message unavailable")
      observePinnedMessageContent(messageId: messageId)
    } else {
      setVisible(false)
    }
  }

  private func observePinnedMessageContent(messageId: Int64) {
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
            embedView.update(with: message, kind: .pinnedInHeader)
          } else {
            embedView.showNotLoaded(kind: .pinnedInHeader, messageText: "Pinned message unavailable")
          }
        }
      )
  }

  private func setVisible(_ visible: Bool) {
    let height = visible ? Self.preferredHeight : 0
    isHidden = !visible
    glassViewTopConstraint?.constant = visible ? 12 : 0
    glassViewBottomConstraint?.constant = visible ? -12 : 0
    embedView.setCollapsed(!visible)
    closeButtonHeightConstraint?.constant = visible ? 24 : 0
    onHeightChange?(height)
  }

  @objc private func unpinTapped() {
    guard let messageId = currentMessageId else { return }
    Task { @MainActor in
      do {
        _ = try await dependencies.realtimeV2.send(.pinMessage(peer: peerId, messageId: messageId, unpin: true))
      } catch {
        Log.shared.error("Failed to unpin message", error: error)
      }
    }
  }
}
