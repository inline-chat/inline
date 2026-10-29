import InlineGrid
import InlineKit
import InlineProtocol
import InlineRTC
import InlineUI
import SwiftUI

private struct GridRoomFlowLayout: Layout {
  let spacing: CGFloat
  let lineSpacing: CGFloat

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache _: inout Void
  ) -> CGSize {
    let availableWidth = proposal.width ?? .infinity
    var maximumRowWidth: CGFloat = 0
    var rowWidth: CGFloat = 0
    var rowHeight: CGFloat = 0
    var totalHeight: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      let proposedRowWidth = rowWidth == 0 ? size.width : rowWidth + spacing + size.width
      if rowWidth > 0, proposedRowWidth > availableWidth {
        maximumRowWidth = max(maximumRowWidth, rowWidth)
        totalHeight += rowHeight + lineSpacing
        rowWidth = size.width
        rowHeight = size.height
      } else {
        rowWidth = proposedRowWidth
        rowHeight = max(rowHeight, size.height)
      }
    }

    maximumRowWidth = max(maximumRowWidth, rowWidth)
    totalHeight += rowHeight
    return CGSize(
      width: proposal.width ?? maximumRowWidth,
      height: totalHeight
    )
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal _: ProposedViewSize,
    subviews: Subviews,
    cache _: inout Void
  ) {
    var origin = bounds.origin
    var rowHeight: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if origin.x > bounds.minX, origin.x + size.width > bounds.maxX {
        origin.x = bounds.minX
        origin.y += rowHeight + lineSpacing
        rowHeight = 0
      }
      subview.place(at: origin, proposal: ProposedViewSize(size))
      origin.x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}

struct GridContent: View {
  let grid: InlineProtocol.Grid?
  let isLoading: Bool
  let didFailLoading: Bool
  let localRoomID: Int64?
  let roomIdentity: (Int64) -> Int64
  let isJoiningDisabled: Bool
  let audioLevel: (Int64) -> Float
  let isScreenSharing: (GridAvatar) -> Bool
  let connectionState: GridMediaConnectionStatus
  let onCreate: () -> Void
  let onRetry: () -> Void
  let onJoin: (Int64) -> Void
  let onLeave: () -> Void
  let onToggleMicrophone: () -> Void
  let onOpenScreenShare: (GridAvatar) -> Void
  let onStopScreenShare: () -> Void
  let onSetTitle: (Int64, String) -> Void
  let onSetLocked: (Int64, Bool) -> Void
  let onDelete: (Int64) -> Void

  /// Your face is one view across rooms, so switching flies it over.
  @Namespace private var faces

  var body: some View {
    ScrollView {
      if let grid {
        GridGlassGroup(spacing: 12) {
          GridRoomFlowLayout(spacing: 12, lineSpacing: 12) {
            ForEach(grid.rooms.map { (roomIdentity($0.id), $0) }, id: \.0) { item in
              let room = item.1
              GridRoomCard(
                room: room,
                isCurrent: localRoomID == room.id || room.isLocalPlaceholder,
                isJoiningDisabled: isJoiningDisabled,
                faces: faces,
                audioLevel: audioLevel,
                isScreenSharing: isScreenSharing,
                connectionState: connectionState,
                onJoin: { onJoin(room.id) },
                onLeave: onLeave,
                onToggleMicrophone: onToggleMicrophone,
                onOpenScreenShare: onOpenScreenShare,
                onStopScreenShare: onStopScreenShare,
                onSetTitle: { onSetTitle(room.id, $0) },
                onSetLocked: { onSetLocked(room.id, $0) },
                onDelete: { onDelete(room.id) }
              )
            }
            GridCreateRoomCard(action: onCreate)
              .disabled(isJoiningDisabled)
          }
        }
        .animation(GridMotion.move, value: grid.gridLayoutKey)
      } else if isLoading {
        ProgressView()
          .controlSize(.small)
          .frame(maxWidth: .infinity, minHeight: 220)
      } else if didFailLoading {
        GridLoadFailureView(onRetry: onRetry)
      } else {
        ProgressView()
          .controlSize(.small)
          .frame(maxWidth: .infinity, minHeight: 220)
      }
    }
    .contentMargins(.horizontal, 28, for: .scrollContent)
    .contentMargins(.top, 8, for: .scrollContent)
    .contentMargins(.bottom, 100, for: .scrollContent)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct GridLoadFailureView: View {
  let onRetry: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label("Grid is temporarily unavailable", systemImage: "exclamationmark.triangle")
    } description: {
      Text("Try loading this space again.")
    } actions: {
      Button("Try Again", action: onRetry)
    }
    .frame(maxWidth: .infinity, minHeight: 260)
  }
}

private struct GridCreateRoomCard: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "plus")
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 68, height: 68)
        .gridRoomGlass(isCurrent: false, accent: Color(nsColor: Theme.accentColor))
    }
    .buttonStyle(GridPressStyle(pressedScale: 0.9))
    .gridHoverLift()
    .help("Create and join a room")
    .accessibilityLabel("Create and join a Grid room")
    .transition(.gridRoom)
  }
}

private struct GridRoomCard: View {
  let room: GridRoom
  let isCurrent: Bool
  let isJoiningDisabled: Bool
  let faces: Namespace.ID
  let audioLevel: (Int64) -> Float
  let isScreenSharing: (GridAvatar) -> Bool
  let connectionState: GridMediaConnectionStatus
  let onJoin: () -> Void
  let onLeave: () -> Void
  let onToggleMicrophone: () -> Void
  let onOpenScreenShare: (GridAvatar) -> Void
  let onStopScreenShare: () -> Void
  let onSetTitle: (String) -> Void
  let onSetLocked: (Bool) -> Void
  let onDelete: () -> Void

  @State private var isHovered = false
  @State private var isRenaming = false
  @State private var titleDraft = ""

  var body: some View {
    ZStack(alignment: .topTrailing) {
      if isCurrent {
        GridRoomSurface(
          room: room,
          isCurrent: true,
          faces: faces,
          audioLevel: audioLevel,
          isScreenSharing: isScreenSharing,
          connectionState: connectionState,
          onLeave: onLeave,
          onToggleMicrophone: onToggleMicrophone,
          onOpenScreenShare: onOpenScreenShare,
          onStopScreenShare: onStopScreenShare
        )
      } else {
        Button(action: onJoin) {
          GridRoomSurface(
            room: room,
            isCurrent: false,
            faces: faces,
            audioLevel: audioLevel,
            isScreenSharing: isScreenSharing,
            connectionState: .disconnected,
            onLeave: onLeave,
            onToggleMicrophone: onToggleMicrophone,
            onOpenScreenShare: onOpenScreenShare,
            onStopScreenShare: onStopScreenShare
          )
        }
        .buttonStyle(GridPressStyle())
        .gridHoverLift()
        .disabled(room.locked || isJoiningDisabled)
      }

      // A room still being made has nothing to name, lock or delete yet.
      if !room.isLocalPlaceholder {
        GridRoomOptionsMenu(
          locked: room.locked,
          canLock: isCurrent,
          canDelete: room.avatars.isEmpty,
          onRename: beginRenaming,
          onSetLocked: onSetLocked,
          onDelete: onDelete
        )
        .opacity(isHovered ? 1 : 0)
        .scaleEffect(isHovered ? 1 : 0.82)
        .padding(3)
        .animation(.smoothSnappy, value: isHovered)
        .allowsHitTesting(isHovered)
      }
    }
    .frame(width: roomWidth, height: 68)
    .overlay(alignment: .top) {
      if room.hasTitle {
        Button(action: beginRenaming) {
          Text(room.title)
            .font(.system(size: 9, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .gridRoomTagGlass()
        }
        .buttonStyle(.plain)
        .help("Rename room")
        .offset(y: -7)
        .transition(.scale(scale: 0.88).combined(with: .opacity))
      }
    }
    .onHover { isHovered = $0 }
    .animation(.smoothSnappy, value: room.hasTitle ? room.title : "")
    .animation(.smoothSnappy, value: room.locked)
    .transition(.gridRoom)
    .alert("Name Room", isPresented: $isRenaming) {
      TextField("Room name", text: $titleDraft)
      Button("Cancel", role: .cancel) {}
      Button("Save") { onSetTitle(titleDraft) }
    } message: {
      Text("Named rooms stay in the Grid when everyone leaves.")
    }
  }

  private func beginRenaming() {
    titleDraft = room.hasTitle ? room.title : ""
    isRenaming = true
  }

  /// One slot per face; a full room stops growing and its last slot shows "+N".
  private var roomWidth: CGFloat {
    let slots = min(room.avatars.count, GridRoomAvatars.maximumVisibleAvatarCount)
    guard slots > 1 else { return 68 }
    return 68 + CGFloat(slots - 1) * 53
  }
}

private struct GridRoomSurface: View {
  let room: GridRoom
  let isCurrent: Bool
  let faces: Namespace.ID
  let audioLevel: (Int64) -> Float
  let isScreenSharing: (GridAvatar) -> Bool
  let connectionState: GridMediaConnectionStatus
  let onLeave: () -> Void
  let onToggleMicrophone: () -> Void
  let onOpenScreenShare: (GridAvatar) -> Void
  let onStopScreenShare: () -> Void

  var body: some View {
    Color.clear
      .overlay {
        GridRoomAvatars(
          avatars: room.avatars,
          faces: faces,
          allowsLocalControls: isCurrent,
          audioLevel: audioLevel,
          isScreenSharing: isScreenSharing,
          showsLocalConnectingIndicator: isCurrent && connectionState == .connecting,
          onLeave: onLeave,
          onToggleMicrophone: onToggleMicrophone,
          onOpenScreenShare: onOpenScreenShare,
          onStopScreenShare: onStopScreenShare
        )
      }
      .overlay(alignment: .bottomTrailing) {
        HStack(spacing: 4) {
          // Room-level disclosure, visible before anyone joins.
          if room.transcriptionIsRunning {
            Image(systemName: "captions.bubble.fill")
              .foregroundStyle(Color(nsColor: Theme.accentColor))
              .help("This room is being transcribed")
              .accessibilityLabel("This room is being transcribed")
              .transition(.scale.combined(with: .opacity))
          }
          if room.locked {
            Image(systemName: "lock.fill")
              .foregroundStyle(.secondary)
              .help("This room is locked")
              .accessibilityLabel("This room is locked")
              .transition(.scale.combined(with: .opacity))
          }
        }
        .font(.system(size: 8, weight: .semibold))
        .padding(7)
      }
      .gridRoomGlass(isCurrent: isCurrent, accent: Color(nsColor: Theme.accentColor))
  }
}

private struct GridRoomOptionsMenu: View {
  let locked: Bool
  let canLock: Bool
  let canDelete: Bool
  let onRename: () -> Void
  let onSetLocked: (Bool) -> Void
  let onDelete: () -> Void

  var body: some View {
    Menu {
      Button(action: onRename) {
        Label("Name Room", systemImage: "pencil")
      }
      Button {
        onSetLocked(!locked)
      } label: {
        Label(
          locked ? "Unlock Room" : "Lock Room",
          systemImage: locked ? "lock.open" : "lock"
        )
      }
      .disabled(!canLock)
      if canDelete {
        Divider()
        Button(role: .destructive, action: onDelete) {
          Label("Delete Room", systemImage: "trash")
        }
      }
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 9, weight: .bold))
        .frame(width: 18, height: 18)
        .background(.regularMaterial, in: Circle())
        .contentShape(Circle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Room options")
  }
}

private struct GridRoomAvatars: View {
  static let maximumVisibleAvatarCount = 5

  let avatars: [GridAvatar]
  let faces: Namespace.ID
  let allowsLocalControls: Bool
  let audioLevel: (Int64) -> Float
  let isScreenSharing: (GridAvatar) -> Bool
  let showsLocalConnectingIndicator: Bool
  let onLeave: () -> Void
  let onToggleMicrophone: () -> Void
  let onOpenScreenShare: (GridAvatar) -> Void
  let onStopScreenShare: () -> Void

  var body: some View {
    HStack(spacing: 4) {
      ForEach(visibleAvatars, id: \.user.id) { avatar in
        GridSpeakingAvatar(
          avatar: avatar,
          allowsLocalControls: allowsLocalControls,
          audioLevel: audioLevel(avatar.user.id),
          isScreenSharing: isScreenSharing(avatar),
          showsConnectingIndicator: showsLocalConnectingIndicator && avatar.ownedByCurrentSession,
          onLeave: onLeave,
          onToggleMicrophone: onToggleMicrophone,
          onOpenScreenShare: { onOpenScreenShare(avatar) },
          onStopScreenShare: onStopScreenShare
        )
        .matchedGeometryEffect(id: avatar.user.id, in: faces)
        .transition(.gridFace)
      }
      if hiddenAvatarCount > 0 {
        if hiddenScreenSharingAvatars.isEmpty {
          overflowLabel
        } else {
          Menu {
            Section("Sharing screens") {
              ForEach(hiddenScreenSharingAvatars, id: \.user.id) { avatar in
                if avatar.ownedByCurrentSession {
                  Button("You are sharing screen") {}
                    .disabled(true)
                  Button("Stop Sharing", role: .destructive, action: onStopScreenShare)
                } else {
                  Button {
                    onOpenScreenShare(avatar)
                  } label: {
                    Label(
                      "View \(InlineKit.User(from: avatar.user).displayName)’s Screen",
                      systemImage: "rectangle.on.rectangle"
                    )
                  }
                }
              }
            }
          } label: {
            overflowLabel
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
          .help("View a shared screen")
          .accessibilityLabel("\(hiddenAvatarCount) more people, including screen sharing")
        }
      }
    }
  }

  private var visibleAvatars: [GridAvatar] {
    GridRoomFaces.visible(avatars, slots: Self.maximumVisibleAvatarCount)
  }

  private var hiddenAvatarCount: Int {
    max(avatars.count - visibleAvatars.count, 0)
  }

  private var hiddenScreenSharingAvatars: [GridAvatar] {
    let shown = Set(visibleAvatars.map(\.user.id))
    return avatars.filter { !shown.contains($0.user.id) && isScreenSharing($0) }
  }

  /// Takes a face's slot, so a full room reads as one more face, not a badge.
  private var overflowLabel: some View {
    Text("+\(hiddenAvatarCount)")
      .font(.system(size: 13, weight: .semibold).monospacedDigit())
      .foregroundStyle(.secondary)
      .frame(width: 45, height: 45)
      .background(Color.primary.opacity(0.08), in: Circle())
      .padding(2)
      .contentTransition(.numericText())
      .transition(.gridFace)
  }
}

private struct GridSpeakingAvatar: View {
  let avatar: GridAvatar
  let allowsLocalControls: Bool
  let audioLevel: Float
  let isScreenSharing: Bool
  let showsConnectingIndicator: Bool
  let onLeave: () -> Void
  let onToggleMicrophone: () -> Void
  let onOpenScreenShare: () -> Void
  let onStopScreenShare: () -> Void

  @State private var isHovered = false

  var body: some View {
    ZStack(alignment: .topLeading) {
      if avatar.ownedByCurrentSession && allowsLocalControls {
        Button(action: onToggleMicrophone) {
          GridAvatarImage(
            user: avatar.user,
            audioLevel: audioLevel,
            microphoneEnabled: avatar.microphoneEnabled,
            showsConnectingIndicator: showsConnectingIndicator,
            size: 45
          )
        }
        .buttonStyle(GridPressStyle(pressedScale: 0.86))
        .help(helpText)
      } else {
        GridAvatarImage(
          user: avatar.user,
          audioLevel: audioLevel,
          microphoneEnabled: avatar.ownedByCurrentSession && !allowsLocalControls ? false : avatar.microphoneEnabled,
          showsConnectingIndicator: false,
          size: 45
        )
        .help(helpText)
      }

      if isScreenSharing {
        GridAvatarScreenShareControl(
          isLocal: avatar.ownedByCurrentSession && allowsLocalControls,
          displayName: InlineKit.User(from: avatar.user).displayName,
          onOpen: onOpenScreenShare,
          onStop: onStopScreenShare
        )
        .offset(x: 23, y: 23)
      }

      if avatar.ownedByCurrentSession && allowsLocalControls, isHovered {
        GridAvatarLeaveButton(action: onLeave)
          .offset(x: -3, y: -3)
          .transition(.scale(scale: 0.72).combined(with: .opacity))
      }
    }
    .onHover { isHovered = $0 }
    .animation(.smoothSnappy, value: isHovered)
  }

  private var helpText: String {
    if avatar.ownedByCurrentSession && allowsLocalControls {
      return isScreenSharing ? "You’re sharing · mute or unmute" : "Mute or unmute"
    }
    if isScreenSharing { return "Open screen" }
    return InlineKit.User(from: avatar.user).displayName
  }
}

private struct GridAvatarLeaveButton: View {
  let action: () -> Void

  @ViewBuilder
  var body: some View {
    if #available(macOS 26.0, *) {
      button
        .glassEffect(.regular.interactive(), in: .circle)
    } else {
      button
        .background(.regularMaterial, in: Circle())
    }
  }

  private var button: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 7, weight: .bold))
        .frame(width: 16, height: 16)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help("Leave room")
    .accessibilityLabel("Leave Grid room")
  }
}

private struct GridAvatarImage: View {
  let user: InlineProtocol.User
  let audioLevel: Float
  let microphoneEnabled: Bool
  let showsConnectingIndicator: Bool
  let size: CGFloat

  var body: some View {
    UserAvatar(user: InlineKit.User(from: user), size: size)
      .padding(2)
      .overlay(
        Circle()
          .stroke(
            showsGreenRing ? Color.green.opacity(ringOpacity) : Color.clear,
            lineWidth: ringWidth
          )
          // Speaking-level updates arrive frequently. Scope their transaction
          // to the ring so avatar loading/content never inherits the animation.
          .animation(.easeOut(duration: 0.12), value: audioLevel)
      )
      .overlay(alignment: .bottomTrailing) {
        if showsConnectingIndicator {
          GridAvatarConnectingIndicator()
        }
      }
  }

  private var ringWidth: CGFloat {
    let level = min(max(CGFloat(audioLevel), 0), 1)
    return 0.7 + level * 0.9
  }

  private var showsGreenRing: Bool {
    microphoneEnabled || audioLevel > 0.01
  }

  private var ringOpacity: Double {
    let level = min(max(Double(audioLevel), 0), 1)
    return microphoneEnabled ? 0.65 + level * 0.25 : 0.55 + level * 0.35
  }
}

private struct GridAvatarScreenShareControl: View {
  let isLocal: Bool
  let displayName: String
  let onOpen: () -> Void
  let onStop: () -> Void

  @State private var isHovered = false

  var body: some View {
    ZStack {
      indicator
        .allowsHitTesting(false)
        .accessibilityHidden(true)

      if isLocal {
        Menu {
          Button("You are sharing screen") {}
            .disabled(true)
          Divider()
          Button("Stop Sharing", role: .destructive, action: onStop)
        } label: {
          hitTarget
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Screen sharing options")
        .accessibilityLabel("Screen sharing options")
      } else {
        Button(action: onOpen) {
          hitTarget
        }
        .buttonStyle(.plain)
        .help("Open \(displayName)’s screen")
        .accessibilityLabel("Open \(displayName)’s screen")
      }
    }
    .frame(width: 32, height: 32)
    .onHover { isHovered = $0 }
    .animation(.smoothSnappy, value: isHovered)
    .transition(.opacity)
  }

  private var hitTarget: some View {
    Color.clear
      .frame(width: 32, height: 32)
      .contentShape(Circle())
  }

  private var indicator: some View {
    Image(systemName: "rectangle.on.rectangle.fill")
      .font(.system(size: 8, weight: .bold))
      .foregroundStyle(.white)
      .frame(width: 22, height: 22)
      .background(Color.green.opacity(isHovered ? 1 : 0.9), in: Circle())
      .overlay {
        Circle().stroke(.white.opacity(isHovered ? 1 : 0.85), lineWidth: 1)
      }
      .scaleEffect(isHovered ? 1.06 : 1)
      .frame(width: 32, height: 32)
  }
}

private struct GridAvatarConnectingIndicator: View {
  @State private var isPulsing = false

  var body: some View {
    Circle()
      .fill(Color(nsColor: Theme.accentColor))
      .frame(width: 7, height: 7)
      .scaleEffect(isPulsing ? 1.2 : 0.85)
      .opacity(isPulsing ? 1 : 0.55)
      .padding(2)
      .background(.regularMaterial, in: Circle())
      .transition(.scale.combined(with: .opacity))
      .onAppear {
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
          isPulsing = true
        }
      }
  }
}
