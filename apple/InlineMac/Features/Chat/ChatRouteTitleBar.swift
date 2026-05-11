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

        if let subtitle = model.status.text {
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
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
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
        ChatIcon(peer: iconPeer, size: Theme.chatToolbarIconSize)
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
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
  }

  private var renamePopover: some View {
    @Bindable var model = model

    return VStack(alignment: .leading, spacing: 0) {
      TextField("Chat Title", text: $model.titleDraft)
        .textFieldStyle(.roundedBorder)
        .focused($isTitleFocused)
        .frame(width: 260)
        .onSubmit {
          model.commitTitleEdit()
        }
        .onExitCommand {
          model.cancelEditingTitle()
        }
    }
    .padding(14)
    .onAppear {
      focusTitleField()
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

private extension View {
  func toolbarWindowDragClickGate(suppressClick: Binding<Bool>) -> some View {
    modifier(ToolbarWindowDragClickGate(suppressClick: suppressClick))
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
