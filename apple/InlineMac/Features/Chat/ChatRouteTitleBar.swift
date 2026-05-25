import AppKit
import InlineKit
import InlineMacUI
import Observation
import SwiftUI

struct ChatRouteTitleBar: View {
  let peer: Peer
  let contextSpaceId: Int64?
  let onTitleChange: (String) -> Void

  @Environment(\.dependencies) private var dependencies
  @Environment(\.mainWindowID) private var mainWindowID
  @Environment(\.nav) private var nav

  @State private var model: ChatRouteToolbarTitleModel
  @State private var suppressClick = false
  @FocusState private var isTitleFocused: Bool

  init(
    peer: Peer,
    db: AppDatabase,
    contextSpaceId: Int64? = nil,
    onTitleChange: @escaping (String) -> Void = { _ in }
  ) {
    self.peer = peer
    self.contextSpaceId = contextSpaceId
    self.onTitleChange = onTitleChange
    _model = State(initialValue: ChatRouteToolbarTitleModel(
      peer: peer,
      db: db,
      contextSpaceId: contextSpaceId
    ))
  }

  var body: some View {
    @Bindable var model = model

    HStack(spacing: 8) {
      avatar

      VStack(alignment: .leading, spacing: 0) {
        titleView

        if let parentThread = model.parentThread {
          parentThreadPill(parentThread)
        } else if let subtitle = model.status.text {
          Text(subtitle)
            .font(.system(size: 11))
            .foregroundStyle(model.status.isTyping ? Color.accentColor : Color.secondary)
            .lineLimit(1)
            .id("subtitle-\(model.status.isTyping)-\(subtitle)")
            .transition(
              .asymmetric(
                insertion: .opacity.combined(with: .offset(y: -2)),
                removal: .opacity
              )
            )
        }
      }
      .frame(minWidth: 0, alignment: .leading)
      .layoutPriority(1)

      Color.clear
        .frame(minWidth: 0, maxWidth: .infinity)
        .toolbarWindowDoubleClickZoom()
    }
    .frame(minWidth: 0, maxWidth: 280, alignment: .leading)
    .toolbarWindowDragClickGate(suppressClick: $suppressClick)
    .animation(.easeInOut(duration: 0.18), value: model.status)
    .contextMenu {
      if model.canRename {
        Button("Rename Chat...", systemImage: "pencil") {
          beginEditingTitle()
        }
      }
    }
    .onAppear {
      model.update(contextSpaceId: contextSpaceId)
      onTitleChange(model.windowTitle)
      registerRenameCommand()
    }
    .onChange(of: model.windowTitle) { _, title in
      onTitleChange(title)
    }
    .onChange(of: contextSpaceId) { _, spaceId in
      model.update(contextSpaceId: spaceId)
      onTitleChange(model.windowTitle)
    }
    .onDisappear {
      unregisterRenameCommand()
    }
  }

  @ViewBuilder
  private var avatar: some View {
    Button(action: handleAvatarClick) {
      if let iconPeer = model.iconPeer {
        SidebarChatIcon(peer: iconPeer, size: Theme.chatToolbarIconSize)
      } else {
        Circle()
          .fill(Color.primary.opacity(0.08))
          .overlay {
            Image(systemName: "bubble.left")
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(.secondary)
          }
          .frame(width: Theme.chatToolbarIconSize, height: Theme.chatToolbarIconSize)
      }
    }
    .buttonStyle(.plain)
    .help("Open Chat Info")
  }

  @ViewBuilder
  private var titleView: some View {
    if model.canRename {
      Button(action: handleTitleClick) {
        titleLabel
      }
      .buttonStyle(.plain)
      .popover(isPresented: Binding(
        get: { model.isEditingTitle },
        set: { isPresented in
          guard !isPresented else { return }
          model.cancelEditingTitle()
        }
      ), arrowEdge: .bottom) {
        renamePopover
      }
      .help("Rename Chat")
      .accessibilityHint("Rename Chat")
    } else {
      titleLabel
    }
  }

  private var titleLabel: some View {
    Text(model.title)
      .font(.system(size: 13, weight: .semibold))
      .lineLimit(1)
      .truncationMode(.tail)
      .frame(minWidth: 0, alignment: .leading)
  }

  private var renamePopover: some View {
    @Bindable var model = model

    return VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        EmojiTextFieldPicker(
          emoji: $model.emojiDraft,
          size: 28,
          placeholderSystemImage: "number",
          accessibilityLabel: "Chat icon"
        )

        TextField("Chat Title", text: $model.titleDraft)
          .textFieldStyle(.roundedBorder)
          .focused($isTitleFocused)
          .frame(width: 226)
          .onSubmit {
            model.commitTitleEdit()
          }
          .onExitCommand {
            model.cancelEditingTitle()
          }
      }
    }
    .padding(14)
    .onAppear {
      focusTitleField()
    }
    .onChange(of: model.emojiDraft) { _, _ in
      guard model.isEditingTitle else { return }
      model.commitTitleEdit()
    }
  }

  private func parentThreadPill(_ parentThread: ChatRouteToolbarTitleModel.ParentThread) -> some View {
    ParentThreadPill(title: parentThread.title) {
      openParentThread(parentThread)
    }
  }

  private func handleAvatarClick() {
    guard !suppressClick else { return }
    openChatInfo()
  }

  private func handleTitleClick() {
    guard !suppressClick else { return }
    beginEditingTitle()
  }

  private func openParentThread(_ parentThread: ChatRouteToolbarTitleModel.ParentThread) {
    guard !suppressClick else { return }
    if let dependencies {
      dependencies.requestOpenChat(peer: parentThread.peer)
    } else {
      nav.open(.chat(peer: parentThread.peer))
    }
  }

  private func openChatInfo() {
    if let dependencies {
      dependencies.openChatInfo(peer: peer)
    } else {
      nav.open(.chatInfo(peer: peer))
    }
  }

  private func beginEditingTitle() {
    guard model.canRename else { return }
    guard !model.isEditingTitle else { return }
    model.startEditingTitle()
  }

  private func registerRenameCommand() {
    guard let mainWindowID else { return }
    MainWindowOpenCoordinator.shared.registerRenameThread(id: mainWindowID) {
      guard model.canRename else { return false }
      guard !model.isEditingTitle else { return true }
      model.startEditingTitle()
      return true
    }
  }

  private func unregisterRenameCommand() {
    guard let mainWindowID else { return }
    MainWindowOpenCoordinator.shared.unregisterRenameThread(id: mainWindowID)
  }

  private func focusTitleField() {
    guard model.isEditingTitle else { return }
    isTitleFocused = true

    Task { @MainActor in
      await Task.yield()
      guard model.isEditingTitle else { return }
      isTitleFocused = true
      NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
    }
  }
}

private struct ParentThreadPill: View {
  let title: String
  let action: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 11))
        .lineLimit(1)
        .foregroundStyle(Color.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(backgroundColor)
        )
        .offset(x: -5)
    }
    .buttonStyle(.plain)
    .help("Open Parent Chat")
    .accessibilityLabel("Open Parent Chat")
    .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    .onHover { isHovered = $0 }
  }

  private var backgroundColor: Color {
    guard isHovered else { return .clear }
    return colorScheme == .dark ? .white.opacity(0.08) : .black.opacity(0.05)
  }
}

private extension View {
  func toolbarWindowDragClickGate(suppressClick: Binding<Bool>) -> some View {
    modifier(ToolbarWindowDragClickGate(suppressClick: suppressClick))
  }

  func toolbarWindowDoubleClickZoom() -> some View {
    modifier(ToolbarWindowDoubleClickZoom())
  }
}

private struct ToolbarWindowDragClickGate: ViewModifier {
  @Binding var suppressClick: Bool

  private let dragThreshold: CGFloat = 3

  func body(content: Content) -> some View {
    content
      .contentShape(Rectangle())
      .simultaneousGesture(WindowDragGesture())
      .simultaneousGesture(clickGateGesture)
      .allowsWindowActivationEvents(true)
  }

  private var clickGateGesture: some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .global)
      .onChanged { value in
        let x = abs(value.translation.width)
        let y = abs(value.translation.height)
        guard max(x, y) > dragThreshold else { return }
        suppressClick = true
      }
      .onEnded { _ in
        DispatchQueue.main.async {
          suppressClick = false
        }
      }
  }
}

private struct ToolbarWindowDoubleClickZoom: ViewModifier {
  @Environment(\.appBridge) private var appBridge

  func body(content: Content) -> some View {
    content
      .contentShape(Rectangle())
      .onTapGesture(count: 2) {
        appBridge?.performWindowZoom()
      }
      .allowsWindowActivationEvents(true)
  }
}
