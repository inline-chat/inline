import AppKit
import Combine
import GRDB
import InlineKit
import Logger
import SwiftUI

final class PinnedMessageHeaderView: NSView {
  private enum Constants {
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 16
    static let contentSpacing: CGFloat = 8
    static let closeButtonSize: CGFloat = 24
  }

  static let preferredHeight: CGFloat = Theme.embeddedMessageHeight + (Constants.verticalPadding * 2)
  private static let backgroundCornerRadius: CGFloat = 14

  private let peerId: Peer
  private let chatId: Int64
  private let dependencies: AppDependencies
  private let log = Log.scoped("PinnedMessageHeaderView")

  var onHeightChange: ((CGFloat) -> Void)?

  private var pinnedMessageObservation: AnyCancellable?
  private var messageObservation: AnyCancellable?
  private var currentMessageId: Int64?

  private let backgroundView: NSView
  private let backgroundContentView: NSView
  private var didStartObservation = false

  private lazy var embedView: EmbeddedMessageView = {
    let view = EmbeddedMessageView(style: .colored)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.showsBackground = false
    view.showsLeadingBar = false
    view.textLeadingPadding = Constants.horizontalPadding
    view.textTrailingPadding = Constants.horizontalPadding
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

  private var backgroundViewTopConstraint: NSLayoutConstraint?
  private var backgroundViewBottomConstraint: NSLayoutConstraint?
  private var closeButtonHeightConstraint: NSLayoutConstraint?

  init(dependencies: AppDependencies, peerId: Peer, chatId: Int64) {
    self.dependencies = dependencies
    self.peerId = peerId
    self.chatId = chatId
    if #available(macOS 26.0, *) {
      let glassView = PinnedMessageGlassBackgroundView(cornerRadius: Self.backgroundCornerRadius)
      backgroundView = glassView
      backgroundContentView = glassView
    } else {
      let glassView = NSVisualEffectView()
      glassView.translatesAutoresizingMaskIntoConstraints = false
      glassView.material = .hudWindow
      glassView.blendingMode = .withinWindow
      glassView.state = .active
      glassView.wantsLayer = true
      glassView.layer?.cornerRadius = Self.backgroundCornerRadius
      glassView.layer?.masksToBounds = true
      glassView.layer?.borderWidth = 0
      glassView.layer?.borderColor = nil
      backgroundView = glassView
      backgroundContentView = glassView
    }
    super.init(frame: .zero)
    setupView()
    setupConstraints()
    setVisible(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true

    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(backgroundView)
    backgroundContentView.addSubview(embedView)
    backgroundContentView.addSubview(closeButton)
    isHidden = true
  }

  private func setupConstraints() {
    backgroundViewTopConstraint = backgroundView.topAnchor.constraint(equalTo: topAnchor, constant: Constants.verticalPadding)
    backgroundViewBottomConstraint = backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Constants.verticalPadding)
    closeButtonHeightConstraint = closeButton.heightAnchor.constraint(equalToConstant: Constants.closeButtonSize)

    NSLayoutConstraint.activate([
      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Constants.horizontalPadding),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Constants.horizontalPadding),
      backgroundViewTopConstraint!,
      backgroundViewBottomConstraint!,

      embedView.leadingAnchor.constraint(equalTo: backgroundContentView.leadingAnchor, constant: Constants.horizontalPadding),
      embedView.centerYAnchor.constraint(equalTo: backgroundContentView.centerYAnchor),
      closeButton.leadingAnchor.constraint(equalTo: embedView.trailingAnchor, constant: Constants.contentSpacing),
      closeButton.trailingAnchor.constraint(equalTo: backgroundContentView.trailingAnchor, constant: -Constants.horizontalPadding),
      closeButton.centerYAnchor.constraint(equalTo: embedView.centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: Constants.closeButtonSize),
      closeButtonHeightConstraint!,
    ])
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
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
        embedView.update(with: message, kind: .pinnedInHeader)
      } else {
        embedView.showNotLoaded(kind: .pinnedInHeader, messageText: "Pinned message unavailable")
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
    backgroundViewTopConstraint?.constant = visible ? Constants.verticalPadding : 0
    backgroundViewBottomConstraint?.constant = visible ? -Constants.verticalPadding : 0
    embedView.setCollapsed(!visible)
    closeButtonHeightConstraint?.constant = visible ? Constants.closeButtonSize : 0
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

@available(macOS 26.0, *)
private final class PinnedMessageGlassBackgroundView: NSView {
  private let hostingView: NSHostingView<PinnedMessageGlassView>

  init(cornerRadius: CGFloat) {
    hostingView = NSHostingView(rootView: PinnedMessageGlassView(cornerRadius: cornerRadius))
    super.init(frame: .zero)

    hostingView.translatesAutoresizingMaskIntoConstraints = false
    hostingView.wantsLayer = true
    hostingView.layer?.backgroundColor = NSColor.clear.cgColor

    addSubview(hostingView)
    NSLayoutConstraint.activate([
      hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
      hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
      hostingView.topAnchor.constraint(equalTo: topAnchor),
      hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

@available(macOS 26.0, *)
private struct PinnedMessageGlassView: View {
  let cornerRadius: CGFloat

  var body: some View {
    Color.clear
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
      .allowsHitTesting(false)
  }
}
