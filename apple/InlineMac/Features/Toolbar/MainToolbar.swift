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
import Logger

enum MainToolbarItemIdentifier: Hashable, Sendable {
  case navigationButtons
  case title
  case spacer
  case translationIcon(peer: Peer)
  case participants(peer: Peer)
  case chatTitle(peer: Peer)
  case nudge(peer: Peer)
  case notifications(peer: Peer)
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
  private enum ToolbarLayoutMetrics {
    static let defaultItemSpacing: CGFloat = 12
    // Keep the trailing action cluster tighter regardless of which optional
    // buttons are present (notifications/nudge/translation/menu).
    static let trailingActionSpacing: CGFloat = 8
  }

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
    contentStackView.spacing = ToolbarLayoutMetrics.defaultItemSpacing
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

    var arrangedItems: [(item: MainToolbarItemIdentifier, view: NSView)] = []
    for item in currentItems {
      guard let view = makeView(for: item) else { continue }
      contentStackView.addArrangedSubview(view)
      arrangedItems.append((item, view))
    }

    for (index, current) in arrangedItems.dropLast().enumerated() {
      let next = arrangedItems[index + 1]
      contentStackView.setCustomSpacing(spacing(after: current.item, before: next.item), after: current.view)
    }
  }

  private func spacing(
    after currentItem: MainToolbarItemIdentifier,
    before nextItem: MainToolbarItemIdentifier
  ) -> CGFloat {
    if currentItem.isTrailingActionItem, nextItem.isTrailingActionItem {
      return ToolbarLayoutMetrics.trailingActionSpacing
    }
    return ToolbarLayoutMetrics.defaultItemSpacing
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

      case let .notifications(peer):
        return DialogNotificationToolbarButton(peer: peer, db: dependencies.database)

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

private extension MainToolbarItemIdentifier {
  var isTrailingActionItem: Bool {
    switch self {
      case .notifications, .participants, .nudge, .translationIcon, .menu:
        return true
      case .navigationButtons, .title, .spacer, .chatTitle:
        return false
    }
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
private final class DialogNotificationToolbarButton: NSButton {
  private let peer: Peer
  private let db: AppDatabase
  private var dialogCancellable: AnyCancellable?
  private lazy var optionsMenu = buildMenu()

  private var selection: DialogNotificationSettingSelection = .global {
    didSet {
      guard oldValue != selection else { return }
      updateIcon()
      updateMenuSelectionState()
    }
  }

  init(peer: Peer, db: AppDatabase) {
    self.peer = peer
    self.db = db
    super.init(frame: .zero)
    configure()
    bindDialog()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func configure() {
    translatesAutoresizingMaskIntoConstraints = false
    isBordered = false
    bezelStyle = .regularSquare
    imagePosition = .imageOnly
    setButtonType(.momentaryChange)
    contentTintColor = .secondaryLabelColor
    imageScaling = .scaleProportionallyDown
    target = self
    action = #selector(showMenu)
    toolTip = "Notifications"

    widthAnchor.constraint(equalToConstant: 28).isActive = true
    heightAnchor.constraint(equalToConstant: 28).isActive = true

    updateIcon()
    updateMenuSelectionState()
    updateAlpha()
  }

  private func bindDialog() {
    db.warnIfInMemoryDatabaseForObservation("DialogNotificationToolbarButton.dialog")
    dialogCancellable = ValueObservation
      .tracking { db in
        try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: self.peer))
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .receive(on: DispatchQueue.main)
      .sink(
        receiveCompletion: { _ in },
        receiveValue: { [weak self] dialog in
          self?.selection = dialog?.notificationSelection ?? .global
        }
      )
  }

  @objc
  private func showMenu() {
    updateMenuSelectionState()
    optionsMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
  }

  @objc
  private func handleMenuSelection(_ sender: NSMenuItem) {
    guard
      let rawValue = sender.representedObject as? String,
      let selected = DialogNotificationSettingSelection(rawValue: rawValue),
      selected != selection
    else {
      return
    }

    let previousSelection = selection
    selection = selected

    Task(priority: .userInitiated) {
      do {
        _ = try await Api.realtime.send(.updateDialogNotificationSettings(peerId: peer, selection: selected))
      } catch {
        Log.shared.error("Failed to update dialog notification settings", error: error)
        await MainActor.run {
          self.selection = previousSelection
        }
      }
    }
  }

  private func updateIcon() {
    let symbolName = switch selection {
      case .global:
        "bell"
      case .all:
        "bell.fill"
      case .mentions:
        "bell.badge"
      case .none:
        "bell.slash"
    }

    if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Notifications") {
      let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold, scale: .medium)
      self.image = image.withSymbolConfiguration(config)
    }
  }

  private func buildMenu() -> NSMenu {
    let menu = NSMenu()
    for option in DialogNotificationSettingSelection.allCases {
      let item = NSMenuItem(title: "", action: #selector(handleMenuSelection(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = option.rawValue
      item.image = menuItemImage(for: option)
      item.attributedTitle = menuItemTitle(for: option)
      menu.addItem(item)
    }
    return menu
  }

  private func updateMenuSelectionState() {
    for item in optionsMenu.items {
      guard
        let rawValue = item.representedObject as? String,
        let option = DialogNotificationSettingSelection(rawValue: rawValue)
      else {
        continue
      }
      item.state = option == selection ? .on : .off
    }
  }

  private func menuItemImage(for option: DialogNotificationSettingSelection) -> NSImage? {
    guard let image = NSImage(systemSymbolName: option.iconName, accessibilityDescription: option.title) else {
      return nil
    }
    return image.withSymbolConfiguration(.init(pointSize: 13, weight: .regular, scale: .medium))
  }

  private func menuItemTitle(for option: DialogNotificationSettingSelection) -> NSAttributedString {
    let titleAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.menuFont(ofSize: 13),
      .foregroundColor: NSColor.labelColor,
    ]
    let descriptionAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11),
      .foregroundColor: NSColor.secondaryLabelColor,
    ]

    let attributed = NSMutableAttributedString(string: option.title, attributes: titleAttributes)
    attributed.append(NSAttributedString(string: "\n"))
    attributed.append(NSAttributedString(string: option.menuDescription, attributes: descriptionAttributes))
    return attributed
  }

  override var isHighlighted: Bool {
    didSet { updateAlpha() }
  }

  override var isEnabled: Bool {
    didSet { updateAlpha() }
  }

  private func updateAlpha() {
    if isHighlighted {
      alphaValue = 0.7
    } else {
      alphaValue = isEnabled ? 1 : 0.35
    }
  }
}

@MainActor
private final class ChatToolbarMenuModel: ObservableObject {
  @Published private(set) var isPinned: Bool = false
  @Published private(set) var isArchived: Bool = false
  @Published private(set) var canRename: Bool = false
  @Published private(set) var chatSpaceId: Int64? = nil

  private let peer: Peer
  private let db: AppDatabase
  private var dialogCancellable: AnyCancellable?
  private var renameCancellable: AnyCancellable?
  private var chatCancellable: AnyCancellable?

  init(peer: Peer, db: AppDatabase) {
    self.peer = peer
    self.db = db
    bindDialog()
    bindRenameEligibility()
    bindChat()
  }

  private func bindDialog() {
    db.warnIfInMemoryDatabaseForObservation("ChatToolbarMenuModel.dialog")
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

    db.warnIfInMemoryDatabaseForObservation("ChatToolbarMenuModel.renameEligibility")
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

  private func bindChat() {
    guard case let .thread(chatId) = peer else {
      chatSpaceId = nil
      return
    }

    db.warnIfInMemoryDatabaseForObservation("ChatToolbarMenuModel.chat")
    chatCancellable = ValueObservation
      .tracking { db in
        try Chat.fetchOne(db, id: chatId)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .receive(on: DispatchQueue.main)
      .sink(
        receiveCompletion: { _ in },
        receiveValue: { [weak self] chat in
          self?.chatSpaceId = chat?.spaceId
        }
      )
  }
}

private struct ChatToolbarMenu: View {
  let peer: Peer
  let spaceId: Int64?
  let dependencies: AppDependencies

  @Environment(\.realtimeV2) private var realtimeV2

  @StateObject private var model: ChatToolbarMenuModel
  @State private var showRenameSheet = false
  @State private var showMoveToSpaceSheet = false
  @State private var showMoveOutConfirm = false
  @State private var loadHistoryTask: Task<Void, Never>?

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

      if peer.isThread {
        if model.chatSpaceId != nil {
          Button("Move Out of Space...", systemImage: "tray.and.arrow.up") {
            showMoveOutConfirm = true
          }
        } else {
          Button("Move to Space...", systemImage: "tray.and.arrow.down") {
            showMoveToSpaceSheet = true
          }
        }
      }

      Button("Load chat history", systemImage: "arrow.down.circle") {
        loadLast1000Messages()
      }
      .disabled(loadHistoryTask != nil)

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
    .sheet(isPresented: $showMoveToSpaceSheet) {
      if let chatId = peer.asThreadId() {
        MoveThreadToSpaceSheet(chatId: chatId, nav2: dependencies.nav2)
      }
    }
    .confirmationDialog(
      "Move this thread out of the space?",
      isPresented: $showMoveOutConfirm,
      titleVisibility: .visible
    ) {
      Button("Move to Home") {
        guard let chatId = peer.asThreadId() else { return }
        showMoveOutConfirm = false
        Task(priority: .userInitiated) {
          await MainActor.run {
            ToastCenter.shared.showLoading("Moving thread…")
          }
          do {
            _ = try await realtimeV2.send(.moveThread(chatID: chatId, spaceID: nil))
            await MainActor.run {
              ToastCenter.shared.dismiss()
              ToastCenter.shared.showSuccess("Moved to Home")
            }
            if let nav2 = dependencies.nav2 {
              // Switching tabs from a `Menu`/confirmation action is timing-sensitive (menu dismissal,
              // transaction optimistic DB write, sidebar observations). Delay slightly, then use Nav2's
              // own resolver to pick the correct tab based on the updated DB state.
              Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                await nav2.openChat(peer: peer, database: dependencies.database)
              }
            }
          } catch {
            await MainActor.run {
              ToastCenter.shared.dismiss()
              ToastCenter.shared.showError("Failed to move thread")
            }
          }
        }
      }
      Button("Cancel", role: .cancel) {}
    }
  }

  private func openChatInfo() {
    if let nav2 = dependencies.nav2 {
      nav2.navigate(to: .chatInfo(peer: peer))
    } else {
      dependencies.nav.open(.chatInfo(peer: peer))
    }
  }

  @MainActor
  private func loadLast1000Messages() {
    guard loadHistoryTask == nil else { return }

    let targetMessageCount = 1_000
    let batchSize: Int32 = 100

    loadHistoryTask = Task(priority: .userInitiated) { @MainActor in
      defer {
        loadHistoryTask = nil
      }

      ToastCenter.shared.showLoading(
        loadingHistoryMessage(loaded: 0, target: targetMessageCount),
        actionTitle: "Cancel",
        action: { cancelHistoryLoad() }
      )

      do {
        let loadedMessages = try await fetchHistoryInBatches(
          targetCount: targetMessageCount,
          batchSize: batchSize
        )
        try Task.checkCancellation()

        ToastCenter.shared.dismiss()
        if loadedMessages > 0 {
          ToastCenter.shared.showSuccess("Loaded \(loadedMessages) messages")
        } else {
          ToastCenter.shared.showSuccess("No older messages to load")
        }
      } catch is CancellationError {
        ToastCenter.shared.dismiss()
        ToastCenter.shared.showSuccess("History loading canceled")
      } catch {
        ToastCenter.shared.dismiss()
        ToastCenter.shared.showError("Failed to load chat history")
      }
    }
  }

  @MainActor
  private func cancelHistoryLoad() {
    loadHistoryTask?.cancel()
  }

  @MainActor
  private func fetchHistoryInBatches(targetCount: Int, batchSize: Int32) async throws -> Int {
    var loadedCount = 0
    var offsetID: Int64?
    var previousOldestMessageID: Int64?

    while loadedCount < targetCount {
      try Task.checkCancellation()

      let remaining = targetCount - loadedCount
      let requestedLimit = Int32(min(Int(batchSize), remaining))

      guard requestedLimit > 0 else { break }

      let rpcResult = try await realtimeV2.send(
        .getChatHistory(peer: peer, offsetID: offsetID, limit: requestedLimit)
      )
      try Task.checkCancellation()

      guard let rpcResult, case let .getChatHistory(result) = rpcResult else {
        throw HistoryLoadError.invalidResponse
      }

      let batchMessages = result.messages
      guard !batchMessages.isEmpty else { break }

      loadedCount += batchMessages.count

      ToastCenter.shared.showLoading(
        loadingHistoryMessage(loaded: min(loadedCount, targetCount), target: targetCount),
        actionTitle: "Cancel",
        action: { cancelHistoryLoad() }
      )

      guard let oldestMessageID = batchMessages.last?.id else { break }
      if let previousOldestMessageID, oldestMessageID >= previousOldestMessageID {
        break
      }

      previousOldestMessageID = oldestMessageID
      offsetID = oldestMessageID

      if batchMessages.count < Int(requestedLimit) {
        break
      }
    }

    return min(loadedCount, targetCount)
  }

  private func loadingHistoryMessage(loaded: Int, target: Int) -> String {
    "Loading chat history… \(loaded)/\(target)"
  }
}

private enum HistoryLoadError: Error {
  case invalidResponse
}
