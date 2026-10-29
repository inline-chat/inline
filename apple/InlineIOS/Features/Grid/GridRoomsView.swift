import Auth
import AVKit
import InlineAudioPlayback
import InlineGrid
import InlineKit
import InlineProtocol
import InlineRTC
import InlineUI
import SwiftUI
import UIKit

/// Uses the same process-owned room service as Home and the active call.
struct GridDestinationView: View {
  let initialSpaceID: Int64?
  @EnvironmentObject private var spaceList: CompactSpaceList

  var body: some View {
    GridRoomsView(
      store: GridIOSRuntime.shared.rooms,
      spaces: spaceList.spaces,
      initialSpaceID: initialSpaceID
    )
  }
}

struct GridRoomsView: View {
  let store: GridRoomService
  let spaces: [InlineKit.Space]
  @State private var selectedSpaceID: Int64?
  @State private var selectedShare: GridScreenShareSelection?
  @State private var didLoadHome = false

  init(store: GridRoomService, spaces: [InlineKit.Space], initialSpaceID: Int64?) {
    self.store = store
    self.spaces = spaces
    _selectedSpaceID = State(initialValue: initialSpaceID)
  }

  private var effectiveSpaceID: Int64? {
    if let selectedSpaceID, store.isEnabled(spaceID: selectedSpaceID) {
      return selectedSpaceID
    }
    if let call = store.currentCall, store.isEnabled(spaceID: call.spaceID) {
      return call.spaceID
    }
    return store.orderedHomeSpaces.first?.spaceID
  }

  /// Rooms stay live while a change is at the server; the newest tap wins.
  private var canCreateRoom: Bool {
    store.callTransferEnabled && store.currentCall?.ownedByCurrentSession != false
  }

  var body: some View {
    content
      .background(Color(.systemBackground))
      .navigationTitle("Grid")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .principal) {
          GridSpacePicker(
            homeSpaces: store.orderedHomeSpaces,
            spaces: spaces,
            selectedSpaceID: effectiveSpaceID,
            onSelect: { selectedSpaceID = $0 }
          )
        }
        if let spaceID = effectiveSpaceID, store.callTransferEnabled {
          ToolbarItem(placement: .topBarTrailing) {
            Button("New Room", systemImage: "plus") { store.createAndJoin(spaceID: spaceID) }
              .disabled(!canCreateRoom)
          }
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        GridCallDock(store: store)
      }
      .task {
        await store.loadHome()
        didLoadHome = true
      }
      .task(id: effectiveSpaceID) {
        if let spaceID = effectiveSpaceID {
          await store.load(spaceID: spaceID)
          store.recordGridOpened(spaceID: spaceID)
        }
      }
      // An error left by an earlier action on Home is stale here.
      .onAppear { store.clearLastError() }
      .onChange(of: store.lastError) { _, error in
        guard let error else { return }
        store.clearLastError()
        // As on the Mac, a failed join or room change shows by rolling back.
        // Only audio that blocks joining needs words.
        if let message = GridJoinBlock.message(for: error) {
          ToastManager.shared.showToast(message, type: .error)
        }
      }
      .fullScreenCover(item: $selectedShare) { selection in
        GridScreenShareViewer(store: store, selection: selection)
      }
  }

  @ViewBuilder
  private var content: some View {
    if let spaceID = effectiveSpaceID {
      if store.callTransferEnabled || store.grid(spaceID: spaceID) == nil {
        GridRoomList(
          store: store,
          spaceID: spaceID,
          canCreateRoom: canCreateRoom,
          onViewShare: { avatar, share in
            guard let identity = store.mediaSessionIdentity else { return }
            selectedShare = GridScreenShareSelection(
              mediaSessionIdentity: identity,
              participantIdentity: share.participantIdentity,
              publicationID: share.publicationID,
              displayName: InlineKit.User(from: avatar.user).displayName
            )
          }
        )
      } else {
        ContentUnavailableView(
          "Grid isn't available on iPhone yet",
          systemImage: "waveform",
          description: Text("You can still join voice rooms from Inline on your Mac.")
        )
      }
    } else if didLoadHome {
      ContentUnavailableView(
        "No spaces with Grid",
        systemImage: "waveform",
        description: Text("Space admins can turn on Grid in space settings.")
      )
    } else {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

/// Only known audio messages reach the interface. SDK and RPC error
/// descriptions can contain diagnostics that do not belong there.
private enum GridJoinBlock {
  static func message(for error: String) -> String? {
    let known: [InlineAudioSessionError] = [.recordingOwnsAudio, .quarantined, .retirementPending]
    return known.map(\.localizedDescription).first { $0 == error }
  }
}

private struct GridSpacePicker: View {
  let homeSpaces: [GridHomeSpace]
  let spaces: [InlineKit.Space]
  let selectedSpaceID: Int64?
  let onSelect: (Int64) -> Void

  private func title(for spaceID: Int64) -> String {
    spaces.first { $0.id == spaceID }?.displayName ?? String(localized: "Grid")
  }

  var body: some View {
    if homeSpaces.count > 1 {
      Menu {
        ForEach(homeSpaces, id: \.spaceID) { home in
          Button {
            onSelect(home.spaceID)
          } label: {
            if home.spaceID == selectedSpaceID {
              Label(title(for: home.spaceID), systemImage: "checkmark")
            } else if home.activeAvatarCount > 0 {
              Text("\(title(for: home.spaceID)) · \(home.activeAvatarCount) talking")
            } else {
              Text(title(for: home.spaceID))
            }
          }
        }
      } label: {
        HStack(spacing: 4) {
          Text(selectedSpaceID.map(title(for:)) ?? String(localized: "Grid"))
            .lineLimit(1)
          Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
        }
        .font(.headline)
        .foregroundStyle(.primary)
      }
      .accessibilityLabel("Choose a space for Grid")
    } else {
      Text(selectedSpaceID.map(title(for:)) ?? String(localized: "Grid"))
        .font(.headline)
        .lineLimit(1)
    }
  }
}

// MARK: - Call state

/// The one call state every Grid surface on iPhone renders. Home, the rooms
/// and the dock all derive it here, so they never disagree mid-transition.
enum GridLocalCall: Equatable {
  enum Claim: Equatable {
    case join
    case move
    case resume
  }

  /// Browsing, or a leave is settling.
  case none
  /// This iPhone is claiming a room; `roomID` is nil while a new room is made.
  case claiming(Claim, spaceID: Int64, roomID: Int64?)
  case active(spaceID: Int64, roomID: Int64, link: GridCallLink)
  /// Listed for this session without media here, e.g. after a relaunch.
  case paused(GridCurrentCall)
  /// Carried by another device.
  case elsewhere(GridCurrentCall)

  @MainActor
  init(store: GridRoomService) {
    switch store.pendingMembership {
      case .leave:
        self = .none
        return
      case let .create(spaceID):
        self = .claiming(.join, spaceID: spaceID, roomID: nil)
        return
      case let .join(spaceID, roomID):
        self = .claiming(.join, spaceID: spaceID, roomID: roomID)
        return
      case let .move(spaceID, roomID):
        let isResume = store.currentCall?.ownedByCurrentSession == true
        self = .claiming(isResume ? .resume : .move, spaceID: spaceID, roomID: roomID)
        return
      case nil:
        break
    }
    guard let call = store.currentCall else {
      self = .none
      return
    }
    if call.ownedByCurrentSession {
      self = store.hasLocalAdmission
        ? .active(spaceID: call.spaceID, roomID: call.roomID, link: GridCallLink(store: store, call: call))
        : .paused(call)
    } else {
      self = store.callTransferEnabled ? .elsewhere(call) : .none
    }
  }

  var spaceID: Int64? {
    switch self {
      case .none: nil
      case let .claiming(_, spaceID, _), let .active(spaceID, _, _): spaceID
      case let .paused(call), let .elsewhere(call): call.spaceID
    }
  }

  /// The room this iPhone is in or is joining.
  var localRoomID: Int64? {
    switch self {
      case let .claiming(_, _, roomID): roomID
      case let .active(_, roomID, _): roomID
      case .none, .paused, .elsewhere: nil
    }
  }

  /// Your microphone and Leave work from the tap on a room, not after the server answers.
  var joiningOrActiveSpaceID: Int64? {
    switch self {
      case let .claiming(.join, spaceID, _), let .active(spaceID, _, _): spaceID
      case .none, .claiming, .paused, .elsewhere: nil
    }
  }

  /// Shown as the Mac's small pulsing dot, never as text.
  var isPending: Bool {
    switch self {
      case .claiming: true
      case let .active(_, _, link): link.isPending
      case .none, .paused, .elsewhere: false
    }
  }
}

/// The local call's media link. Being alone in a room has no media session
/// by design, so that is not a pending state.
enum GridCallLink: Equatable {
  case live
  case alone
  case connecting
  case reconnecting
  /// Nothing will retry; the dock says why and offers an action.
  case failed

  @MainActor
  init(store: GridRoomService, call: GridCurrentCall) {
    // Read alone from the room, not the transport: tearing down media after
    // the last person leaves must not read as connecting.
    let room = store.grid(spaceID: call.spaceID)?.rooms.first { $0.id == call.roomID }
    if let room, room.avatars.count <= 1 {
      self = .alone
      return
    }
    switch store.media.connectionState {
      case .connected: self = .live
      // Someone is here and media has not started yet.
      case .disconnected: self = .connecting
      case .connecting: self = store.media.isReconnecting ? .reconnecting : .connecting
      case .failed: self = .failed
    }
  }

  var isPending: Bool {
    self == .connecting || self == .reconnecting
  }
}

/// The Mac's connecting indicator: a small pulsing accent dot on your face.
struct GridConnectingDot: View {
  @State private var isPulsing = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Circle()
      .fill(Color.accentColor)
      .frame(width: 7, height: 7)
      .scaleEffect(isPulsing ? 1.2 : 0.85)
      .opacity(isPulsing ? 1 : 0.55)
      .padding(2)
      .background(.regularMaterial, in: Circle())
      .transition(.scale.combined(with: .opacity))
      .onAppear {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
          isPulsing = true
        }
      }
      .accessibilityLabel("Connecting")
  }
}

// MARK: - Rooms

enum GridRoomTitle {
  /// Named rooms keep their name; others are described by who else is in them.
  static func title(for room: GridRoom) -> String {
    if let name = name(of: room) {
      return name
    }
    let others = room.avatars.filter { !$0.ownedByCurrentSession }
    let names = others.prefix(2).map { InlineKit.User(from: $0.user).shortDisplayName }
    switch (names.count, others.count) {
      case (0, _): return room.avatars.isEmpty ? String(localized: "Empty room") : String(localized: "Just you")
      case (1, 1): return names[0]
      case (2, 2): return String(localized: "\(names[0]) and \(names[1])")
      default: return String(localized: "\(names[0]), \(names[1]) +\(others.count - 2)")
    }
  }

  static func name(of room: GridRoom) -> String? {
    guard room.hasTitle else { return nil }
    let title = room.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? nil : title
  }
}

private struct GridRoomList: View {
  let store: GridRoomService
  let spaceID: Int64
  let canCreateRoom: Bool
  let onViewShare: (GridAvatar, InlineRTCScreenShare) -> Void

  /// Your face is one view across rooms, so switching flies it over.
  @Namespace private var faces

  var body: some View {
    let call = GridLocalCall(store: store)
    ScrollView {
      if let grid = store.grid(spaceID: spaceID) {
        // Rooms keep the server's order, as on the Mac: they never jump.
        GridGlassGroup(spacing: 12) {
          GridRoomFlowLayout(spacing: 12) {
            ForEach(grid.rooms.map { (store.displayIdentity(roomID: $0.id), $0) }, id: \.0) { item in
              GridRoomCapsule(store: store, call: call, room: item.1, faces: faces, onViewShare: onViewShare)
                .transition(.gridRoom)
            }
            // A new room shows at once as a stand-in with you in it.
            Button {
              store.createAndJoin(spaceID: spaceID)
            } label: {
              Image(systemName: "plus")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: GridRoomCapsule.roomSize, height: GridRoomCapsule.roomSize)
                .gridRoomGlass(isCurrent: false, accent: .accentColor)
            }
            .buttonStyle(GridPressStyle(pressedScale: 0.9))
            .disabled(!canCreateRoom)
            .accessibilityLabel("Create and join a Grid room")
          }
        }
        // Room names sit on the top edge, as on the Mac.
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .animation(GridMotion.move, value: grid.gridLayoutKey)
      } else if store.failedLoadSpaceIDs.contains(spaceID) {
        ContentUnavailableView {
          Label("Couldn't load rooms", systemImage: "wifi.exclamationmark")
        } actions: {
          Button("Try Again") { Task { await store.load(spaceID: spaceID) } }
        }
        .padding(.top, 60)
      } else {
        ProgressView().frame(maxWidth: .infinity, minHeight: 160)
      }
    }
  }
}

/// A room is a bubble of faces, as on the Mac. Tap to join; in your room, tap
/// your face to mute. Names and room actions live in the long-press menu.
private struct GridRoomCapsule: View {
  let store: GridRoomService
  let call: GridLocalCall
  let room: GridRoom
  let faces: Namespace.ID
  let onViewShare: (GridAvatar, InlineRTCScreenShare) -> Void
  @State private var isRenaming = false
  @State private var draftTitle = ""

  /// Faces fit four to a room on any iPhone; a fuller room shows "+N" in the last slot.
  private static let visibleAvatarCount = 4
  /// Your face with its microphone ring; rooms are sized from it.
  static let faceSize: CGFloat = 56
  static let roomSize: CGFloat = faceSize + 16

  /// You are in this room on this iPhone, or joining it.
  private var isCurrent: Bool {
    call.localRoomID == room.id || room.isLocalPlaceholder
  }

  private var holdsCallElsewhere: Bool {
    switch call {
      case let .paused(current), let .elsewhere(current): current.roomID == room.id
      case .none, .claiming, .active: false
    }
  }

  private var isDisabled: Bool {
    if holdsCallElsewhere {
      return !store.callTransferEnabled
    }
    return !store.callTransferEnabled || room.locked || store.currentCall?.ownedByCurrentSession == false
  }

  var body: some View {
    Group {
      if isCurrent {
        surface
      } else {
        Button(action: join) { surface }
          .buttonStyle(GridPressStyle())
          .disabled(isDisabled)
      }
    }
    // A room still being made has nothing to name, lock or delete yet.
    .contextMenu {
      if !room.isLocalPlaceholder { roomMenu }
    }
    .overlay(alignment: .top) {
      if let name = GridRoomTitle.name(of: room) {
        Text(name)
          .font(.caption.weight(.medium))
          .lineLimit(1)
          .padding(.horizontal, 7)
          .padding(.vertical, 2)
          .gridRoomTagGlass()
          .offset(y: -10)
          .allowsHitTesting(false)
          .transition(.scale(scale: 0.88).combined(with: .opacity))
      }
    }
    .sensoryFeedback(.impact(weight: .light), trigger: isCurrent) { _, isCurrent in isCurrent }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityLabel)
    .alert("Name Room", isPresented: $isRenaming) {
      TextField("Room name", text: $draftTitle)
      Button("Save") {
        let title = draftTitle
        Task { await store.setRoomTitle(roomID: room.id, title: title) }
      }
      Button("Cancel", role: .cancel) {}
    }
  }

  private var surface: some View {
    let visible = GridRoomFaces.visible(room.avatars, slots: Self.visibleAvatarCount)
    return HStack(spacing: 6) {
      ForEach(visible, id: \.user.id) { avatar in
        GridRoomFace(
          store: store,
          call: call,
          avatar: avatar,
          isCurrentRoom: isCurrent,
          onViewShare: onViewShare
        )
        .matchedGeometryEffect(id: avatar.user.id, in: faces)
        .transition(.gridFace)
      }
      if room.avatars.count > visible.count {
        // Takes a face's slot, so a full room reads as one more face, not a badge.
        Text("+\(room.avatars.count - visible.count)")
          .font(.subheadline.monospacedDigit().weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: Self.faceSize, height: Self.faceSize)
          .background(Color.primary.opacity(0.08), in: Circle())
          .contentTransition(.numericText())
          .transition(.gridFace)
      }
    }
    .padding(8)
    .frame(minWidth: Self.roomSize, minHeight: Self.roomSize)
    .overlay(alignment: .bottomTrailing) {
      HStack(spacing: 4) {
        if room.transcriptionIsRunning {
          Image(systemName: "captions.bubble.fill")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("This room is being transcribed")
            .transition(.scale.combined(with: .opacity))
        }
        if room.locked {
          Image(systemName: "lock.fill")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .transition(.scale.combined(with: .opacity))
        }
      }
      .padding(7)
    }
    .gridRoomGlass(isCurrent: isCurrent, accent: .accentColor)
    .animation(GridMotion.move, value: room.locked)
    .animation(GridMotion.move, value: room.transcriptionIsRunning)
  }

  private func join() {
    if holdsCallElsewhere {
      store.moveCallHere()
    } else {
      store.join(roomID: room.id)
    }
  }

  @ViewBuilder
  private var roomMenu: some View {
    if !room.avatars.isEmpty {
      Section {
        ForEach(room.avatars, id: \.user.id) { avatar in
          let user = InlineKit.User(from: avatar.user)
          Label(user.displayName, systemImage: avatar.microphoneEnabled ? "mic" : "mic.slash")
        }
      }
    }
    Button("Name Room", systemImage: "pencil") {
      draftTitle = GridRoomTitle.name(of: room) ?? ""
      isRenaming = true
    }
    if isCurrent, case .active = call {
      Button(room.locked ? "Unlock Room" : "Lock Room", systemImage: room.locked ? "lock.open" : "lock") {
        let locked = !room.locked
        Task { await store.toggleRoomLock(roomID: room.id, locked: locked) }
      }
      Button("Leave Room", systemImage: "door.left.hand.open", role: .destructive) {
        store.leaveCurrentRoom(spaceID: room.spaceID)
      }
    }
    if room.avatars.isEmpty {
      Button("Delete Room", systemImage: "trash", role: .destructive) {
        Task { await store.deleteRoom(roomID: room.id) }
      }
    }
  }

  private var accessibilityLabel: String {
    let title = GridRoomTitle.title(for: room)
    if isCurrent { return String(localized: "\(title), you're here") }
    if holdsCallElsewhere {
      if case .paused = call {
        return String(localized: "Resume Grid in \(title)")
      }
      return String(localized: "Move Grid here, \(title)")
    }
    return String(localized: "Join \(title)")
  }
}

/// A face with the Mac's microphone ring: green while the mic is open, wider
/// as the person speaks. Your own face in your room toggles your microphone.
private struct GridRoomFace: View {
  let store: GridRoomService
  let call: GridLocalCall
  let avatar: GridAvatar
  let isCurrentRoom: Bool
  let onViewShare: (GridAvatar, InlineRTCScreenShare) -> Void

  private var isYouHere: Bool {
    isCurrentRoom && avatar.ownedByCurrentSession
  }

  var body: some View {
    if isYouHere, let spaceID = call.joiningOrActiveSpaceID {
      GridMicrophoneToggle(store: store, spaceID: spaceID) { _ in face }
        .accessibilityHint("Mutes or unmutes your microphone")
    } else {
      face
    }
  }

  private var face: some View {
    let level = isCurrentRoom ? store.audioLevel(userID: avatar.user.id) : 0
    let microphoneOpen = avatar.microphoneEnabled
    let shares = isCurrentRoom ? store.screenShares(avatar: avatar) : []
    let user = InlineKit.User(from: avatar.user)

    return UserAvatar(user: user, size: GridRoomCapsule.faceSize - 4)
      .padding(2)
      .overlay {
        Circle()
          .strokeBorder(
            microphoneOpen || level > 0.01 ? Color.green.opacity(0.65 + Double(min(level, 1)) * 0.3) : .clear,
            lineWidth: 1.5 + CGFloat(min(level, 1)) * 1.5
          )
          .animation(.easeOut(duration: 0.12), value: level)
      }
      .overlay(alignment: .bottomTrailing) {
        if isYouHere, call.isPending {
          GridConnectingDot()
        }
      }
      .overlay(alignment: .topTrailing) {
        if !shares.isEmpty {
          Menu {
            ForEach(shares) { share in
              Button("View Screen", systemImage: "rectangle.on.rectangle") {
                onViewShare(avatar, share)
              }
            }
          } label: {
            Image(systemName: "rectangle.on.rectangle.fill")
              .font(.system(size: 8, weight: .bold))
              .foregroundStyle(.white)
              .frame(width: 18, height: 18)
              .background(Color.green, in: Circle())
              .frame(minWidth: 44, minHeight: 44, alignment: .topTrailing)
          }
          .accessibilityLabel("View \(user.displayName)’s screen")
        }
      }
      .animation(.smooth(duration: 0.2), value: call.isPending)
      .accessibilityLabel(user.displayName)
      .accessibilityValue(microphoneOpen ? String(localized: "Microphone on") : String(localized: "Muted"))
  }
}

// MARK: - Call controls

/// Bottom controls for your call: the same row from the tap on a room until
/// you leave, otherwise a way to bring the call here.
struct GridCallDock: View {
  let store: GridRoomService

  var body: some View {
    let call = GridLocalCall(store: store)
    Group {
      switch call {
        case let .claiming(.join, spaceID, _), let .active(spaceID, _, _):
          GridLocalCallControls(store: store, call: call, spaceID: spaceID)
        case .claiming(.resume, _, _):
          // Cancel withdraws this iPhone's claim rather than leaving the room.
          GridDockNotice(text: String(localized: "Resuming…"), actionTitle: String(localized: "Cancel")) {
            store.withdrawLocalAdmission()
          }
        case .claiming:
          GridDockNotice(text: String(localized: "Moving call here…"), actionTitle: String(localized: "Cancel")) {
            store.withdrawLocalAdmission()
          }
        case .paused:
          GridDockNotice(text: String(localized: "Call paused"), actionTitle: String(localized: "Resume")) {
            store.moveCallHere()
          }
          .disabled(!store.callTransferEnabled)
        case let .elsewhere(current):
          GridDockNotice(text: GridCallOwner.label(for: current), actionTitle: String(localized: "Move here")) {
            store.moveCallHere()
          }
        case .none:
          EmptyView()
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.bottom, 12)
    .animation(.smooth(duration: 0.25), value: call)
    .modifier(GridTranscriptionSubtitle(store: store))
  }
}

enum GridCallOwner {
  static func label(for call: GridCurrentCall) -> String {
    switch call.ownerClientType.lowercased() {
      case "macos": String(localized: "On your Mac")
      case "ios": String(localized: "On another iPhone")
      default: String(localized: "On another device")
    }
  }

  static func systemImage(for call: GridCurrentCall) -> String {
    call.ownerClientType.lowercased() == "macos" ? "laptopcomputer" : "iphone"
  }
}

private struct GridDockNotice: View {
  let text: String
  var isProblem = false
  let actionTitle: String
  let action: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      if isProblem {
        Image(systemName: "exclamationmark.circle.fill")
          .foregroundStyle(.orange)
      }
      Text(text)
        .foregroundStyle(isProblem ? .primary : .secondary)
      Button(actionTitle, action: action)
        .fontWeight(.semibold)
        .foregroundStyle(Color.accentColor)
        .buttonStyle(.plain)
    }
    .font(.footnote)
    .padding(.horizontal, 14)
    .frame(minHeight: 36)
    .gridGlassCapsule()
  }
}

/// Problems the call can't fix by retrying, as the Mac's small notices above
/// the controls. Connecting and reconnecting never show here.
private struct GridCallProblem {
  let text: String
  let actionTitle: String
  let action: () -> Void

  @MainActor
  init?(store: GridRoomService, call: GridLocalCall, spaceID: Int64) {
    guard case let .active(_, _, link) = call else { return nil }
    let media = store.media
    let leave = { store.leaveCurrentRoom(spaceID: spaceID) }
    let retry = { store.retryAudio() }
    if InlineAudioSession.shared.isQuarantined {
      self.init(InlineAudioSessionError.quarantined.localizedDescription, String(localized: "Leave Room"), leave)
    } else if media.providerCircuitOpen {
      self.init(String(localized: "Voice connection paused"), String(localized: "Leave Room"), leave)
    } else if case let .failed(message) = media.audioState {
      let known: [InlineAudioSessionError] = [.recordingOwnsAudio, .retirementPending, .routeUnavailable]
      let text = known.map(\.localizedDescription).first { $0 == message }
        ?? String(localized: "Grid audio couldn’t start")
      self.init(text, String(localized: "Try Again"), retry)
    } else if media.isAudioSafetyPaused {
      self.init(String(localized: "Audio paused"), String(localized: "Resume"), retry)
    } else if link == .failed {
      self.init(String(localized: "Voice connection failed"), String(localized: "Try Again"), retry)
    } else if media.isMicrophoneEnabled, media.localAudioFlowState == .missing {
      self.init(String(localized: "Microphone audio stopped"), String(localized: "Try Again"), retry)
    } else if media.hasRemoteAudioFlowFailure {
      self.init(String(localized: "Incoming audio stalled"), String(localized: "Try Again"), retry)
    } else {
      return nil
    }
  }

  private init(_ text: String, _ actionTitle: String, _ action: @escaping () -> Void) {
    self.text = text
    self.actionTitle = actionTitle
    self.action = action
  }
}

private struct GridLocalCallControls: View {
  let store: GridRoomService
  let call: GridLocalCall
  let spaceID: Int64
  private let audio = InlineAudioSession.shared

  var body: some View {
    VStack(spacing: 10) {
      if let problem = GridCallProblem(store: store, call: call, spaceID: spaceID) {
        GridDockNotice(text: problem.text, isProblem: true, actionTitle: problem.actionTitle, action: problem.action)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }

      HStack(spacing: 20) {
        GridMicrophoneButton(store: store, spaceID: spaceID, style: .large)
        if let room = store.currentSessionRoom, room.transcriptionAvailable || room.transcriptionIsRunning {
          GridTranscriptionButton(store: store, room: room)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        }
        GridNativeAudioRoutePicker(routeName: audio.currentRouteName)
          .frame(width: 52, height: 52)
          .gridGlassCircle()
        GridLeaveButton(store: store, spaceID: spaceID, style: .large)
      }
    }
  }
}

/// Toggles your microphone, as on the Mac: any time you are in a room, alone
/// or not. The choice carries into your next join. A tap during an audio
/// safety pause is the user's decision and ends the pause.
struct GridMicrophoneToggle<Label: View>: View {
  let store: GridRoomService
  let spaceID: Int64
  @ViewBuilder let label: (_ isOn: Bool) -> Label
  @State private var requestedUnmute = false
  @State private var showsPermissionAlert = false
  @Environment(\.openURL) private var openURL

  private var isOn: Bool { store.media.isMicrophoneEnabled }

  private var isInCall: Bool {
    GridLocalCall(store: store).joiningOrActiveSpaceID == spaceID
  }

  var body: some View {
    Button(action: toggle) { label(isOn) }
      .buttonStyle(GridPressStyle(pressedScale: 0.86))
      .disabled(!isInCall)
      .accessibilityLabel(isOn ? String(localized: "Mute microphone") : String(localized: "Unmute microphone"))
      .onChange(of: store.media.microphonePermission) { _, permission in
        if requestedUnmute, permission == .denied || permission == .restricted {
          showsPermissionAlert = true
          requestedUnmute = false
        } else if permission == .authorized {
          requestedUnmute = false
        }
      }
      .alert("Microphone access is off", isPresented: $showsPermissionAlert) {
        Button("Open Settings") {
          if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Allow microphone access in Settings to talk in Grid.")
      }
  }

  private func toggle() {
    if !isOn {
      if store.media.microphonePermission == .denied || store.media.microphonePermission == .restricted {
        showsPermissionAlert = true
        return
      }
      requestedUnmute = true
    } else {
      requestedUnmute = false
    }
    store.toggleMicrophone(spaceID: spaceID)
  }
}

/// The Mac's mic control: green with a white mic when on, plain when muted.
struct GridMicrophoneButton: View {
  enum Style {
    case compact
    case large
  }

  let store: GridRoomService
  let spaceID: Int64
  let style: Style

  private var diameter: CGFloat { style == .large ? 52 : 26 }

  var body: some View {
    GridMicrophoneToggle(store: store, spaceID: spaceID) { isOn in
      let icon = Image(systemName: isOn ? "mic.fill" : "mic.slash.fill")
        .font(style == .large ? .title3.weight(.medium) : .system(size: 11, weight: .semibold))
        .foregroundStyle(isOn ? Color.white : Color.primary)
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
      if isOn {
        icon.background(Color.green, in: Circle())
      } else if style == .large {
        icon.gridGlassCircle()
      } else {
        icon.background(Color.primary.opacity(0.08), in: Circle())
      }
    }
    .animation(.easeOut(duration: 0.15), value: store.media.isMicrophoneEnabled)
  }
}

/// The Mac's leave control: a pink door.
struct GridLeaveButton: View {
  enum Style {
    case compact
    case large
  }

  let store: GridRoomService
  let spaceID: Int64
  let style: Style

  private var diameter: CGFloat { style == .large ? 52 : 26 }

  var body: some View {
    Button {
      store.leaveCurrentRoom(spaceID: spaceID)
    } label: {
      let icon = Image(systemName: "door.left.hand.open")
        .font(style == .large ? .title3.weight(.medium) : .system(size: 11, weight: .semibold))
        .foregroundStyle(.pink)
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
      if style == .large {
        icon.gridGlassCircle()
      } else {
        icon.background(Color.primary.opacity(0.08), in: Circle())
      }
    }
    .buttonStyle(GridPressStyle(pressedScale: 0.86))
    .accessibilityLabel("Leave Grid room")
  }
}

private struct GridNativeAudioRoutePicker: UIViewRepresentable {
  let routeName: String

  func makeUIView(context: Context) -> AVRoutePickerView {
    let view = AVRoutePickerView()
    view.prioritizesVideoDevices = false
    view.tintColor = .label
    view.activeTintColor = UIColor(Color.accentColor)
    view.accessibilityLabel = String(localized: "Audio output")
    view.accessibilityValue = routeName
    return view
  }

  func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
    uiView.accessibilityValue = routeName
  }
}

private extension View {
  @ViewBuilder
  func gridGlassCapsule() -> some View {
    if #available(iOS 26.0, *) {
      glassEffect(.regular, in: Capsule())
    } else {
      background(.regularMaterial, in: Capsule())
    }
  }

  @ViewBuilder
  func gridGlassCircle() -> some View {
    if #available(iOS 26.0, *) {
      glassEffect(.regular.interactive(), in: Circle())
    } else {
      background(.regularMaterial, in: Circle())
    }
  }
}

private struct GridRoomFlowLayout: Layout {
  let spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var usedWidth: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width {
        y += rowHeight + spacing
        x = 0
        rowHeight = 0
      }
      usedWidth = max(usedWidth, x + size.width)
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
    return CGSize(width: proposal.width ?? usedWidth, height: y + rowHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX
    var y = bounds.minY
    var rowHeight: CGFloat = 0
    var row: [(LayoutSubview, CGSize, CGFloat)] = []

    // Bottom-align each row so rooms of any height share a baseline.
    func flush() {
      for (view, size, rowX) in row {
        view.place(at: CGPoint(x: rowX, y: y + rowHeight - size.height), proposal: ProposedViewSize(size))
      }
      row.removeAll()
    }

    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > bounds.minX, x + size.width > bounds.maxX {
        flush()
        y += rowHeight + spacing
        x = bounds.minX
        rowHeight = 0
      }
      row.append((view, size, x))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
    flush()
  }
}
