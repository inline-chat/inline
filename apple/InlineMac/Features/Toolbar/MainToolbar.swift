import AppKit
import QuartzCore
import Auth
import Combine
import GRDB
import InlineKit
import InlineMacWindow
import InlineUI
import SwiftUI
import Translation

enum MainToolbarItemIdentifier: Hashable, Sendable {
  case navigationButtons
  case title
  case spacer
  case translationIcon(peer: Peer)
  case participants(peer: Peer)
  case chatTitle(peer: Peer)
  case nudge(peer: Peer)
  case menu(peer: Peer)
}

struct MainToolbarItems {
  var items: [MainToolbarItemIdentifier]
  var transparent: Bool {
    items.count == 0
  }
}

extension MainToolbarItems {
  static var empty: MainToolbarItems {
    MainToolbarItems(items: [])
  }

  static func defaultItems() -> MainToolbarItems {
    MainToolbarItems(items: [.navigationButtons, .title])
  }
}

class MainToolbarView: NSView {
  private var dependencies: AppDependencies
  private var contentLeadingConstraint: NSLayoutConstraint?
  private let backgroundView = MainToolbarBackgroundView()
  private let contentStackView = NSStackView()
  private var currentItems: [MainToolbarItemIdentifier] = []
  private var chatTitleToolbar: ChatTitleToolbar?
  private weak var navBackButton: NSButton?
  private weak var navForwardButton: NSButton?

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    super.init(frame: .zero)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(with toolbar: MainToolbarItems) {
    transparent = toolbar.transparent
    let itemsChanged = currentItems != toolbar.items
    if itemsChanged {
      currentItems = toolbar.items
      rebuildContent()
    }
    updateNavigationButtonStates()
    chatTitleToolbar?.configure()
  }

  func updateLeadingPadding(
    _ padding: CGFloat,
    animated: Bool = false,
    duration: TimeInterval = 0.2
  ) {
    guard contentLeadingConstraint?.constant != padding else { return }
    if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = duration
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        context.allowsImplicitAnimation = true
        contentLeadingConstraint?.animator().constant = padding
        layoutSubtreeIfNeeded()
      }
    } else {
      contentLeadingConstraint?.constant = padding
      layoutSubtreeIfNeeded()
    }
  }

  // MARK: - UI

  var transparent: Bool = false {
    didSet {
      updateLayer()
      contentStackView.isHidden = transparent
      backgroundView.isHidden = transparent
    }
  }

  // MARK: - Setup

  private func setupView() {
    wantsLayer = true
    layer?.backgroundColor = .clear

    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(backgroundView)

    contentStackView.translatesAutoresizingMaskIntoConstraints = false
    contentStackView.orientation = .horizontal
    contentStackView.alignment = .centerY
    contentStackView.spacing = 12
    contentStackView.setContentHuggingPriority(.defaultLow, for: .horizontal)
    addSubview(contentStackView)

    let leadingConstraint = contentStackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
    contentLeadingConstraint = leadingConstraint
    NSLayoutConstraint.activate([
      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
      backgroundView.topAnchor.constraint(equalTo: topAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

      leadingConstraint,
      contentStackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      contentStackView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
      contentStackView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
      contentStackView.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  // MARK: - Lifecycle

  override func updateLayer() {
    layer?.backgroundColor = .clear
    super.updateLayer()
  }

  private func rebuildContent() {
    chatTitleToolbar = nil
    for view in contentStackView.arrangedSubviews {
      contentStackView.removeArrangedSubview(view)
      view.removeFromSuperview()
    }

    for item in currentItems {
      guard let view = makeView(for: item) else { continue }
      contentStackView.addArrangedSubview(view)
    }
  }

  private func makeView(for item: MainToolbarItemIdentifier) -> NSView? {
    switch item {
      case .navigationButtons:
        return makeNavigationButtonsView()

      case let .translationIcon(peer):
        return makeHostingView(
          TranslationButton(peer: peer)
            .buttonStyle(ToolbarButtonStyle())
            .id(peer.id)
        )

      case let .nudge(peer):
        return makeHostingView(
          NudgeButton(peer: peer)
            .buttonStyle(ToolbarButtonStyle())
            .id(peer.id)
        )

      case let .participants(peer):
        return makeHostingView(
          ParticipantsToolbarButton(peer: peer, dependencies: dependencies)
            .id(peer.id)
        )

      case let .chatTitle(peer):
        let toolbarItem = ChatTitleToolbar(peer: peer, dependencies: dependencies)
        chatTitleToolbar = toolbarItem
        guard let view = toolbarItem.view else { return nil }
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view

      case .spacer:
        return makeSpacerView()

      case .title:
        return makeTitlePlaceholderView()

      case let .menu(peer):
        return makeHostingView(
          ChatToolbarMenu(
            peer: peer,
            database: dependencies.database,
            spaceId: dependencies.nav2?.activeSpaceId,
            dependencies: dependencies
          )
          .id(peer.id)
        )
    }
  }

  private func makeHostingView<Content: View>(_ view: Content) -> NSView {
    let hostingView = NSHostingView(
      rootView: ToolbarHostingContainer(content: view)
        .ignoresSafeArea()
    )
    hostingView.translatesAutoresizingMaskIntoConstraints = false
    return hostingView
  }

  private func makeNavigationButtonsView() -> NSView {
    let stack = NSStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 0

    let backButton = ToolbarIconButton(
      systemName: "chevron.left",
      target: self,
      action: #selector(handleBack)
    )
    let forwardButton = ToolbarIconButton(
      systemName: "chevron.right",
      target: self,
      action: #selector(handleForward)
    )

    navBackButton = backButton
    navForwardButton = forwardButton
    updateNavigationButtonStates()

    stack.addArrangedSubview(backButton)
    stack.addArrangedSubview(forwardButton)
    return stack
  }

  private func makeSpacerView() -> NSView {
    let spacer = ToolbarDragAreaView()
    spacer.translatesAutoresizingMaskIntoConstraints = false
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
    return spacer
  }

  private func makeTitlePlaceholderView() -> NSView {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.widthAnchor.constraint(equalToConstant: 0).isActive = true
    return view
  }

  private func updateNavigationButtonStates() {
    navBackButton?.isEnabled = dependencies.nav2?.canGoBack ?? false
    navForwardButton?.isEnabled = dependencies.nav2?.canGoForward ?? false
  }

  @objc private func handleBack() {
    dependencies.nav2?.goBack()
  }

  @objc private func handleForward() {
    dependencies.nav2?.goForward()
  }
}

private final class MainToolbarBackgroundView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    wantsLayer = true
  }

  override var wantsUpdateLayer: Bool {
    true
  }

  override func makeBackingLayer() -> CALayer {
    CAGradientLayer()
  }

  override func updateLayer() {
    guard let gradientLayer = layer as? CAGradientLayer else { return }
    // Theme colors here are dynamic (depend on NSAppearance). Resolve them for the
    // current effective appearance before converting to CGColor, otherwise the
    // gradient can render as black when the user forces Light/Dark in settings.
    let baseColor = Theme.windowContentBackgroundColor.resolvedColor(with: effectiveAppearance)
    gradientLayer.colors = [
      baseColor.withAlphaComponent(1).cgColor,
      baseColor.withAlphaComponent(0.97).cgColor,
      baseColor.withAlphaComponent(0.9).cgColor,
      baseColor.withAlphaComponent(0.35).cgColor,
      baseColor.withAlphaComponent(0).cgColor,
    ]
    gradientLayer.locations = [0, 0.2, 0.5, 0.85, 1]
    gradientLayer.startPoint = CGPoint(x: 0.5, y: 1)
    gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateLayer()
  }
}

private final class ToolbarIconButton: NSButton {
  init(systemName: String, target: AnyObject?, action: Selector?) {
    super.init(frame: .zero)
    configure(systemName: systemName, target: target, action: action)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isHighlighted: Bool {
    didSet { updateAlpha() }
  }

  override var isEnabled: Bool {
    didSet { updateAlpha() }
  }

  private func configure(systemName: String, target: AnyObject?, action: Selector?) {
    translatesAutoresizingMaskIntoConstraints = false
    isBordered = false
    bezelStyle = .regularSquare
    imagePosition = .imageOnly
    setButtonType(.momentaryChange)
    contentTintColor = .secondaryLabelColor
    imageScaling = .scaleProportionallyDown
    self.target = target
    self.action = action

    if let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) {
      let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold, scale: .medium)
      self.image = image.withSymbolConfiguration(config)
    }

    widthAnchor.constraint(equalToConstant: 28).isActive = true
    heightAnchor.constraint(equalToConstant: 28).isActive = true
    updateAlpha()
  }

  private func updateAlpha() {
    if isHighlighted {
      alphaValue = 0.7
    } else {
      alphaValue = isEnabled ? 1 : 0.35
    }
  }
}

private final class ToolbarDragAreaView: NSView {
  override var mouseDownCanMoveWindow: Bool {
    false
  }

  override func mouseDown(with event: NSEvent) {
    window?.beginWindowDrag(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    if event.clickCount == 2 {
      let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
      if action == "Minimize" {
        window?.performMiniaturize(nil)
      } else {
        window?.performZoom(nil)
      }
    }
  }
}

private struct ToolbarHostingContainer<Content: View>: View {
  let content: Content

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 0)
      content
      Spacer(minLength: 0)
    }
    .frame(height: Theme.toolbarHeight)
  }
}

@MainActor
private final class ChatToolbarMenuModel: ObservableObject {
  @Published private(set) var isPinned: Bool = false
  @Published private(set) var isArchived: Bool = false
  @Published private(set) var canRename: Bool = false

  private let peer: Peer
  private let db: AppDatabase
  private var dialogCancellable: AnyCancellable?
  private var renameCancellable: AnyCancellable?

  init(peer: Peer, db: AppDatabase) {
    self.peer = peer
    self.db = db
    bindDialog()
    bindRenameEligibility()
  }

  private func bindDialog() {
    dialogCancellable = ValueObservation
      .tracking { db in
        try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: self.peer))
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .receive(on: DispatchQueue.main)
      .sink(
        receiveCompletion: { _ in },
        receiveValue: { [weak self] dialog in
          guard let self else { return }
          self.isPinned = dialog?.pinned ?? false
          self.isArchived = dialog?.archived ?? false
        }
      )
  }

  private func bindRenameEligibility() {
    guard case let .thread(chatId) = peer else {
      canRename = false
      return
    }
    guard let currentUserId = Auth.shared.getCurrentUserId() else {
      canRename = false
      return
    }

    renameCancellable = ValueObservation
      .tracking { db in
        if let chat = try Chat.fetchOne(db, id: chatId),
           chat.isPublic == true,
           let spaceId = chat.spaceId
        {
          return try Member
            .filter(Member.Columns.userId == currentUserId)
            .filter(Member.Columns.spaceId == spaceId)
            .filter(Member.Columns.canAccessPublicChats == true)
            .fetchOne(db) != nil
        }

        return try ChatParticipant
          .filter(Column("chatId") == chatId)
          .filter(Column("userId") == currentUserId)
          .fetchOne(db) != nil
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .receive(on: DispatchQueue.main)
      .sink(
        receiveCompletion: { _ in },
        receiveValue: { [weak self] isParticipant in
          self?.canRename = isParticipant
        }
      )
  }
}

private struct ChatToolbarMenu: View {
  let peer: Peer
  let spaceId: Int64?
  let dependencies: AppDependencies

  @StateObject private var model: ChatToolbarMenuModel
  @State private var showRenameSheet = false

  init(peer: Peer, database: AppDatabase, spaceId: Int64?, dependencies: AppDependencies) {
    self.peer = peer
    self.spaceId = spaceId
    self.dependencies = dependencies
    _model = StateObject(wrappedValue: ChatToolbarMenuModel(peer: peer, db: database))
  }

  var body: some View {
    Menu {
      Button("Chat Info", systemImage: "info.circle") {
        openChatInfo()
      }

      if peer.isThread, model.canRename {
        Button("Rename Chat...", systemImage: "pencil") {
          showRenameSheet = true
        }
      }

      Divider()

      Button(
        model.isPinned ? "Unpin" : "Pin",
        systemImage: model.isPinned ? "pin.slash.fill" : "pin.fill"
      ) {
        Task(priority: .userInitiated) {
          try await DataManager.shared.updateDialog(
            peerId: peer,
            pinned: !model.isPinned,
            spaceId: spaceId
          )
        }
      }

      Button(
        model.isArchived ? "Unarchive" : "Archive",
        systemImage: "archivebox.fill"
      ) {
        Task(priority: .userInitiated) {
          try await DataManager.shared.updateDialog(
            peerId: peer,
            archived: !model.isArchived,
            spaceId: spaceId
          )
        }
      }
    } label: {
      Image(systemName: "ellipsis")
    }
    .menuStyle(.button)
    .buttonStyle(ToolbarButtonStyle())
    .menuIndicator(.hidden)
    .fixedSize()
    .onReceive(NotificationCenter.default.publisher(for: .renameThread)) { _ in
      guard peer.isThread, model.canRename else { return }
      showRenameSheet = true
    }
    .sheet(isPresented: $showRenameSheet) {
      RenameChatSheet(peer: peer)
    }
  }

  private func openChatInfo() {
    if let nav2 = dependencies.nav2 {
      nav2.navigate(to: .chatInfo(peer: peer))
    } else {
      dependencies.nav.open(.chatInfo(peer: peer))
    }
  }
}
