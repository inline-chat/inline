import AppKit
import Auth
import Combine
import GRDB
import InlineKit
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

final class ToolbarState: ObservableObject {
  @Published var currentItems: [MainToolbarItemIdentifier]

  init() {
    currentItems = [.navigationButtons]
  }

  func update(with items: [MainToolbarItemIdentifier]) {
    currentItems = items
  }
}

class MainToolbarView: NSView {
  private var dependencies: AppDependencies
  private var hostingView: NSHostingView<ToolbarSwiftUIView>?
  private var hostingLeadingConstraint: NSLayoutConstraint?

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
    state.update(with: toolbar.items)
    transparent = toolbar.transparent

    // Force SwiftUI to refresh in case Observation misses changes from AppKit
    // hostingView?.rootView = ToolbarSwiftUIView(
    //   state: state,
    //   dependencies: dependencies
    // )
  }

  func updateLeadingPadding(
    _ padding: CGFloat,
    animated: Bool = false,
    duration: TimeInterval = 0.2
  ) {
    guard hostingLeadingConstraint?.constant != padding else { return }
    if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = duration
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        context.allowsImplicitAnimation = true
        hostingLeadingConstraint?.animator().constant = padding
        layoutSubtreeIfNeeded()
      }
    } else {
      hostingLeadingConstraint?.constant = padding
      layoutSubtreeIfNeeded()
    }
  }

  // MARK: - UI

  var transparent: Bool = false {
    didSet {
      updateLayer()
      hostingView?.isHidden = transparent
    }
  }

  // MARK: - State

  var state = ToolbarState()

  // MARK: - Setup

  private func setupView() {
    wantsLayer = true
    layer?.backgroundColor = .clear

    // Add SwiftUI view to the toolbar
    let hostingView = NSHostingView(
      rootView: ToolbarSwiftUIView(
        state: state,
        dependencies: dependencies
      )
    )
    self.hostingView = hostingView
    hostingView.translatesAutoresizingMaskIntoConstraints = false
    hostingView.setContentHuggingPriority(
      .defaultLow,
      for: .horizontal
    )
    addSubview(hostingView)
    let leadingConstraint = hostingView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
    hostingLeadingConstraint = leadingConstraint
    NSLayoutConstraint.activate([
      leadingConstraint,
      hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
      hostingView.topAnchor.constraint(equalTo: topAnchor),
      hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  // MARK: - Lifecycle

  override func updateLayer() {
    layer?.backgroundColor = .clear
    super.updateLayer()
  }
}

// Swift UI representation of the toolbar
struct ToolbarSwiftUIView: View {
  @ObservedObject var state: ToolbarState
  var dependencies: AppDependencies

  private enum ToolbarButtonMetrics {
    static let symbolSize: CGFloat = 14
    static let size: CGFloat = 28
  }

  var body: some View {
    ZStack(alignment: .leading) {
      toolbarBackground
      toolbarContent
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 10)
    }
    .frame(height: Theme.toolbarHeight)
    .ignoresSafeArea()
  }

  private var toolbarBackground: some View {
    let baseColor = Color(nsColor: Theme.windowContentBackgroundColor)
    return LinearGradient(
      gradient: Gradient(stops: [
        .init(color: baseColor.opacity(1), location: 0),
        .init(color: baseColor.opacity(0.97), location: 0.2),
        .init(color: baseColor.opacity(0.9), location: 0.5),
        .init(color: baseColor.opacity(0.35), location: 0.85),
        .init(color: baseColor.opacity(0), location: 1),
      ]),
      startPoint: .top,
      endPoint: .bottom
    )
  }

  @ViewBuilder
  private var toolbarContent: some View {
    HStack(spacing: 12) {
      ForEach(state.currentItems, id: \.self) { item in
        switch item {
          case .navigationButtons:
            navigationButtons

          case let .translationIcon(peer):
            if #available(macOS 26.0, *) {
              TranslationButton(peer: peer)
                .buttonStyle(ToolbarButtonStyle())
                // .padding(.horizontal, 0)
                // .frame(height: Theme.toolbarHeight)
                .id(peer.id)
            } else {
              TranslationButton(peer: peer)
                .buttonStyle(ToolbarButtonStyle())
                // .frame(height: Theme.toolbarHeight - 8)
                .id(peer.id)
            }

          case let .nudge(peer):
            if #available(macOS 26.0, *) {
              NudgeButton(peer: peer)
                .buttonStyle(ToolbarButtonStyle())
                .id(peer.id)
            } else {
              NudgeButton(peer: peer)
                .buttonStyle(ToolbarButtonStyle())
                .id(peer.id)
            }

          case let .participants(peer):
            ParticipantsToolbarButton(peer: peer, dependencies: dependencies)
              .id(peer.id)

          case let .chatTitle(peer):
            ChatTitleToolbarRepresentable(peer: peer, dependencies: dependencies)
              .id(peer.id)

          case .spacer:
            Spacer()

          case .title:
            EmptyView()

          case let .menu(peer):
            ChatToolbarMenu(
              peer: peer,
              database: dependencies.database,
              spaceId: dependencies.nav2?.activeSpaceId,
              dependencies: dependencies
            )
            .id(peer.id)
        }
      }
    }
  }

  private var navigationBackButton: some View {
    navigationButton(
      systemName: "chevron.left",
      isEnabled: dependencies.nav2?.canGoBack ?? false
    ) {
      dependencies.nav2?.goBack()
    }
  }

  private var navigationButtons: some View {
    HStack(spacing: 0) {
      navigationBackButton
      navigationForwardButton
    }
  }

  private var navigationForwardButton: some View {
    navigationButton(
      systemName: "chevron.right",
      isEnabled: dependencies.nav2?.canGoForward ?? false
    ) {
      dependencies.nav2?.goForward()
    }
  }

  private func navigationButton(
    systemName: String,
    isEnabled: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
    }
    .buttonStyle(ToolbarButtonStyle())
    .contentShape(Rectangle())
    .opacity(isEnabled ? 1 : 0.35)
    .disabled(!isEnabled)
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

// Bridge the existing AppKit chat title toolbar into SwiftUI
private struct ChatTitleToolbarRepresentable: NSViewRepresentable {
  let peer: Peer
  let dependencies: AppDependencies

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    let toolbarItem = ChatTitleToolbar(peer: peer, dependencies: dependencies)
    context.coordinator.toolbarItem = toolbarItem
    return toolbarItem.view ?? NSView()
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.toolbarItem?.configure()
  }

  class Coordinator {
    var toolbarItem: ChatTitleToolbar?
  }
}
