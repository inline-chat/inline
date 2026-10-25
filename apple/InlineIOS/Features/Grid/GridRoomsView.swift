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

  private var canCreateRoom: Bool {
    !store.membershipMutationInFlight && store.callTransferEnabled
      && store.currentCall?.ownedByCurrentSession != false
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

  var isClaimingRoom: Bool {
    if case .claiming(.join, _, _) = self { true } else { false }
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

  var body: some View {
    let call = GridLocalCall(store: store)
    // A new room has no id until the server makes it; the add tile stands in.
    let isCreatingRoom = call.isClaimingRoom && call.localRoomID == nil && call.spaceID == spaceID
    ScrollView {
      if let grid = store.grid(spaceID: spaceID) {
        // Rooms keep the server's order, as on the Mac: they never jump.
        GridRoomFlowLayout(spacing: 10) {
          ForEach(grid.rooms, id: \.id) { room in
            GridRoomCapsule(store: store, call: call, room: room, onViewShare: onViewShare)
          }
          Button {
            store.createAndJoin(spaceID: spaceID)
          } label: {
            Group {
              if isCreatingRoom {
                ProgressView()
              } else {
                Image(systemName: "plus")
              }
            }
            .font(.body.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: 58, height: 58)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
          }
          .buttonStyle(.plain)
          .disabled(!canCreateRoom)
          .accessibilityLabel("Create and join a Grid room")
        }
        .padding(16)
        .animation(.smooth(duration: 0.25), value: grid.rooms.map(\.id))
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
  let onViewShare: (GridAvatar, InlineRTCScreenShare) -> Void
  @State private var isRenaming = false
  @State private var draftTitle = ""

  private static let visibleAvatarCount = 4

  /// You are in this room on this iPhone, or joining it.
  private var isCurrent: Bool {
    call.localRoomID == room.id
  }

  private var holdsCallElsewhere: Bool {
    switch call {
      case let .paused(current), let .elsewhere(current): current.roomID == room.id
      case .none, .claiming, .active: false
    }
  }

  private var isDisabled: Bool {
    if holdsCallElsewhere {
      return store.membershipMutationInFlight || !store.callTransferEnabled
    }
    return store.membershipMutationInFlight || !store.callTransferEnabled || room.locked
      || store.currentCall?.ownedByCurrentSession == false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let name = GridRoomTitle.name(of: room) {
        Text(name)
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .padding(.leading, 6)
      }
      Group {
        if isCurrent {
          faces
        } else {
          Button(action: join) { faces }
            .buttonStyle(.plain)
            .disabled(isDisabled)
        }
      }
      .contextMenu { roomMenu }
    }
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

  private var faces: some View {
    HStack(spacing: 6) {
      if room.avatars.isEmpty {
        Image(systemName: "person")
          .font(.body)
          .foregroundStyle(.tertiary)
          .frame(width: 42, height: 42)
      }
      ForEach(room.avatars.prefix(Self.visibleAvatarCount), id: \.user.id) { avatar in
        GridRoomFace(
          store: store,
          call: call,
          avatar: avatar,
          isCurrentRoom: isCurrent,
          onViewShare: onViewShare
        )
        .transition(.scale(scale: 0.76).combined(with: .opacity))
      }
      if room.avatars.count > Self.visibleAvatarCount {
        Text("+\(room.avatars.count - Self.visibleAvatarCount)")
          .font(.caption.monospacedDigit().weight(.medium))
          .foregroundStyle(.secondary)
          .frame(minWidth: 24)
      }
    }
    .padding(8)
    .background(
      isCurrent ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05),
      in: RoundedRectangle(cornerRadius: 18, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(isCurrent ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1)
    }
    .overlay(alignment: .bottomTrailing) {
      if room.locked {
        Image(systemName: "lock.fill")
          .font(.system(size: 8, weight: .semibold))
          .foregroundStyle(.secondary)
          .padding(6)
      }
    }
    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .animation(.smooth(duration: 0.25), value: room.avatars.map(\.user.id))
    .animation(.smooth(duration: 0.25), value: isCurrent)
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
    if isYouHere, case let .active(spaceID, _, _) = call {
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

    return UserAvatar(user: user, size: 42)
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
    guard case let .active(callSpaceID, _, _) = GridLocalCall(store: store) else { return false }
    return callSpaceID == spaceID
  }

  var body: some View {
    Button(action: toggle) { label(isOn) }
      .buttonStyle(.plain)
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
    .buttonStyle(.plain)
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

    // Bottom-align each row so named rooms (with a label above) line up.
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
