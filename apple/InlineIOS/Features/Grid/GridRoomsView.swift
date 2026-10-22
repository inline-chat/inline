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
      store: GridRuntime.shared.rooms,
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
  @State private var presentedFailure: GridActionFailure?
  @State private var didLoadHome = false
  @Environment(\.dismiss) private var dismiss

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

  private var actionFailure: GridActionFailure? {
    let hasConnectionFailure = store.media.connectionState == .failed
    let connectionError = hasConnectionFailure ? store.media.lastConnectionError : nil
    let audioError: String? = if case let .failed(message) = store.media.audioState {
      message
    } else {
      nil
    }
    let storeError = store.membershipMutationInFlight ? nil : store.lastError
    let errors = [storeError, connectionError, audioError].compactMap(\.self)
    let hasMediaFailure = hasConnectionFailure || audioError != nil || store.media.providerCircuitOpen
    let audio = InlineAudioSession.shared
    if audio.isQuarantined && (store.hasLocalAdmission || !errors.isEmpty)
      || errors.contains(InlineAudioSessionError.quarantined.localizedDescription)
    {
      return .restartRequired
    }
    guard !errors.isEmpty || hasMediaFailure else { return nil }
    if errors.contains(InlineAudioSessionError.recordingOwnsAudio.localizedDescription) {
      return .recordingConflict
    }
    if errors.contains(InlineAudioSessionError.retirementPending.localizedDescription) {
      return .retirementPending
    }
    return hasMediaFailure ? .audio : .update
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
        if let spaceID = effectiveSpaceID {
          GridCallDock(store: store, spaceID: store.currentCall?.spaceID ?? spaceID)
        }
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
      .onChange(of: actionFailure, initial: true) { _, failure in
        if let failure {
          presentedFailure = failure
          store.clearLastError()
        }
      }
      .alert(presentedFailure?.title ?? "Unable to update Grid", isPresented: Binding(
        get: { presentedFailure != nil },
        set: {
          if !$0 {
            presentedFailure = nil
          }
        }
      ), presenting: presentedFailure) { failure in
        if failure.canRetryAudio && store.hasLocalAdmission {
          Button("Retry Audio") {
            guard store.hasLocalAdmission, store.currentCall?.ownedByCurrentSession == true,
                  !InlineAudioSession.shared.isQuarantined else { return }
            store.retryAudio()
          }
          .disabled(store.membershipMutationInFlight)
        } else if failure == .update {
          Button("Refresh") {
            Task {
              await store.loadHome()
              if let spaceID = effectiveSpaceID {
                await store.load(spaceID: spaceID)
              }
            }
          }
        }
        if let call = store.currentCall, call.ownedByCurrentSession {
          Button("Leave Grid", role: .destructive) {
            if let current = store.currentCall, current.ownedByCurrentSession {
              store.leaveCurrentRoom(spaceID: current.spaceID)
            }
          }
        }
        if failure == .recordingConflict || failure == .restartRequired {
          Button("Close Grid", role: .cancel) { dismiss() }
        } else {
          Button("Cancel", role: .cancel) {}
        }
      } message: { failure in
        Text(failure.message)
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

/// Only known recovery messages reach the native surface. SDK and RPC error
/// descriptions can contain diagnostics that do not belong in the interface.
private enum GridActionFailure: Equatable {
  case recordingConflict
  case restartRequired
  case retirementPending
  case audio
  case update

  var title: LocalizedStringKey {
    self == .update ? "Unable to update Grid" : "Unable to start Grid audio"
  }

  var message: String {
    switch self {
      case .recordingConflict: InlineAudioSessionError.recordingOwnsAudio.localizedDescription
      case .restartRequired: InlineAudioSessionError.quarantined.localizedDescription
      case .retirementPending: InlineAudioSessionError.retirementPending.localizedDescription
      case .audio: String(localized: "Grid audio could not start. Try again.")
      case .update: String(localized: "Grid could not be updated. Refresh and try again.")
    }
  }

  var canRetryAudio: Bool {
    self == .audio || self == .retirementPending
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

// MARK: - Rooms

enum GridRoomTitle {
  /// Named rooms keep their name; others are described by who is in them.
  static func title(for room: GridRoom) -> String {
    if let name = name(of: room) {
      return name
    }
    let names = room.avatars.prefix(2).map { InlineKit.User(from: $0.user).shortDisplayName }
    switch (names.count, room.avatars.count) {
      case (0, _): return String(localized: "Empty room")
      case (1, 1): return names[0]
      case (2, 2): return String(localized: "\(names[0]) and \(names[1])")
      default: return String(localized: "\(names[0]), \(names[1]) +\(room.avatars.count - 2)")
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
    ScrollView {
      if let grid = store.grid(spaceID: spaceID) {
        GridRoomFlowLayout(spacing: 10) {
          ForEach(sortedRooms(grid.rooms), id: \.id) { room in
            GridRoomCapsule(store: store, room: room, onViewShare: onViewShare)
          }
          Button {
            store.createAndJoin(spaceID: spaceID)
          } label: {
            Image(systemName: "plus")
              .font(.body.weight(.medium))
              .foregroundStyle(.secondary)
              .frame(width: 58, height: 58)
              .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                  .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
              }
              .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
          }
          .buttonStyle(.plain)
          .disabled(!canCreateRoom)
          .accessibilityLabel("Create and join a Grid room")
        }
        .padding(16)
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

  /// Your room first, then rooms with people, then empty rooms.
  private func sortedRooms(_ rooms: [GridRoom]) -> [GridRoom] {
    let currentRoomID = store.currentCall?.roomID
    return rooms.enumerated().sorted { lhs, rhs in
      let lhsRank = lhs.element.id == currentRoomID ? 0 : lhs.element.avatars.isEmpty ? 2 : 1
      let rhsRank = rhs.element.id == currentRoomID ? 0 : rhs.element.avatars.isEmpty ? 2 : 1
      return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
    }.map(\.element)
  }
}

/// A room is a bubble of faces, as in the Mac sidebar. Tap to join; names
/// and room actions live in the long-press menu.
private struct GridRoomCapsule: View {
  let store: GridRoomService
  let room: GridRoom
  let onViewShare: (GridAvatar, InlineRTCScreenShare) -> Void
  @State private var isRenaming = false
  @State private var draftTitle = ""

  private static let visibleAvatarCount = 4

  private var isCurrent: Bool {
    store.currentCall?.roomID == room.id && store.currentCall?.ownedByCurrentSession == true
      && store.hasLocalAdmission
  }

  private var holdsCallElsewhere: Bool {
    store.currentCall?.roomID == room.id && !isCurrent
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
          .foregroundStyle(isCurrent ? Color.green : .secondary)
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
        GridRoomFace(store: store, avatar: avatar, isCurrentRoom: isCurrent, onViewShare: onViewShare)
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
      isCurrent ? Color.green.opacity(0.14) : Color.primary.opacity(0.05),
      in: RoundedRectangle(cornerRadius: 18, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(isCurrent ? Color.green.opacity(0.5) : .clear, lineWidth: 1)
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
    if isCurrent {
      Button(room.locked ? "Unlock Room" : "Lock Room", systemImage: room.locked ? "lock.open" : "lock") {
        let locked = !room.locked
        Task { await store.toggleRoomLock(roomID: room.id, locked: locked) }
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
      return store.currentCall?.ownedByCurrentSession == true
        ? String(localized: "Resume Grid in \(title)") : String(localized: "Move Grid here, \(title)")
    }
    return String(localized: "Join \(title)")
  }
}

private struct GridRoomFace: View {
  let store: GridRoomService
  let avatar: GridAvatar
  let isCurrentRoom: Bool
  let onViewShare: (GridAvatar, InlineRTCScreenShare) -> Void

  var body: some View {
    let speaking = isCurrentRoom && store.audioLevel(userID: avatar.user.id) > 0.01
    let shares = isCurrentRoom ? store.screenShares(avatar: avatar) : []
    let user = InlineKit.User(from: avatar.user)

    UserAvatar(user: user, size: 42)
      .padding(2)
      .overlay {
        Circle().strokeBorder(speaking ? Color.green : .clear, lineWidth: 2)
      }
      .overlay(alignment: .bottomTrailing) {
        if isCurrentRoom, !avatar.microphoneEnabled {
          Image(systemName: "mic.slash.fill")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 16, height: 16)
            .background(Color(.systemBackground), in: Circle())
            .accessibilityLabel("Muted")
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
              .foregroundStyle(Color.accentColor)
              .frame(width: 16, height: 16)
              .background(Color(.systemBackground), in: Circle())
              .frame(minWidth: 44, minHeight: 44, alignment: .topTrailing)
          }
          .accessibilityLabel("View \(user.displayName)’s screen")
        }
      }
      .animation(.easeOut(duration: 0.15), value: speaking)
      .accessibilityLabel(user.displayName)
  }
}

// MARK: - Call controls

/// Bottom controls for the call in this space: local controls when this device
/// carries it, otherwise a way to bring it here.
struct GridCallDock: View {
  let store: GridRoomService
  let spaceID: Int64

  var body: some View {
    Group {
      if let call = store.currentCall, call.spaceID == spaceID {
        if call.ownedByCurrentSession, store.hasLocalAdmission {
          GridLocalCallControls(store: store, spaceID: spaceID)
        } else if store.callTransferEnabled {
          if store.membershipMutationInFlight {
            GridDockNotice(text: String(localized: "Moving call…"), actionTitle: String(localized: "Cancel")) {
              store.withdrawLocalAdmission()
            }
          } else {
            GridDockNotice(
              text: call.ownedByCurrentSession
                ? String(localized: "Call paused") : String(localized: "On another device"),
              actionTitle: call.ownedByCurrentSession ? String(localized: "Resume") : String(localized: "Move here")
            ) {
              store.moveCallHere()
            }
          }
        }
      } else if store.membershipMutationInFlight {
        GridDockNotice(text: String(localized: "Joining…"), actionTitle: String(localized: "Cancel")) {
          store.withdrawLocalAdmission()
        }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.bottom, 12)
  }
}

private struct GridDockNotice: View {
  let text: String
  let actionTitle: String
  let action: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Text(text)
        .font(.footnote)
        .foregroundStyle(.secondary)
      Button(actionTitle, action: action)
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.green)
        .buttonStyle(.plain)
    }
    .padding(.horizontal, 14)
    .frame(minHeight: 36)
    .gridGlassCapsule()
  }
}

private struct GridLocalCallControls: View {
  let store: GridRoomService
  let spaceID: Int64
  private let audio = InlineAudioSession.shared

  var body: some View {
    VStack(spacing: 10) {
      if store.media.isAudioSafetyPaused {
        GridDockNotice(text: String(localized: "Audio paused"), actionTitle: String(localized: "Resume")) {
          store.retryAudio()
        }
        .disabled(store.membershipMutationInFlight)
      }

      HStack(spacing: 20) {
        GridMicrophoneButton(store: store, spaceID: spaceID, style: .large)
        GridNativeAudioRoutePicker(routeName: audio.currentRouteName)
          .frame(width: 52, height: 52)
          .gridGlassCircle()
        GridLeaveButton(store: store, spaceID: spaceID, diameter: 52)
      }
    }
  }
}

/// Mute toggle shared by Home and the Grid screen. Unmuting is only offered
/// when someone else is in the room, matching iOS listen-only admission.
struct GridMicrophoneButton: View {
  enum Style {
    case compact
    case large
  }

  private enum AudioAlert {
    case microphonePermission
  }

  let store: GridRoomService
  let spaceID: Int64
  let style: Style
  /// Compact controls hand a blocked unmute to the full Grid screen.
  var onBlocked: (() -> Void)?
  @State private var requestedUnmute = false
  @State private var audioAlert: AudioAlert?
  @Environment(\.openURL) private var openURL

  private var isOn: Bool { store.media.isMicrophoneEnabled }

  private var canUnmute: Bool {
    guard !store.media.isAudioSafetyPaused,
          let roomID = store.currentCall?.roomID,
          let room = store.grid(spaceID: spaceID)?.rooms.first(where: { $0.id == roomID })
    else { return false }
    return room.avatars.count > 1
  }

  var body: some View {
    Group {
      switch style {
        case .compact:
          Button(action: toggle) {
            Image(systemName: isOn ? "mic.fill" : "mic.slash.fill")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(isOn ? Color.primary : Color.red)
              .frame(width: 26, height: 26)
              .background(Color(.systemBackground).opacity(0.8), in: Circle())
          }
          .buttonStyle(.plain)
        case .large:
          Button(action: toggle) {
            Image(systemName: isOn ? "mic.fill" : "mic.slash.fill")
              .font(.title3.weight(.medium))
              .foregroundStyle(isOn ? Color.primary : Color.red)
              .frame(width: 52, height: 52)
              .gridGlassCircle()
          }
          .buttonStyle(.plain)
      }
    }
    .disabled(!isOn && (store.membershipMutationInFlight || (!canUnmute && onBlocked == nil)))
    .opacity(!isOn && !canUnmute ? 0.5 : 1)
    .accessibilityLabel(isOn ? String(localized: "Mute microphone") : String(localized: "Unmute microphone"))
    .onChange(of: store.media.microphonePermission) { _, permission in
      if requestedUnmute, permission == .denied || permission == .restricted {
        audioAlert = .microphonePermission
        requestedUnmute = false
      } else if permission == .authorized {
        requestedUnmute = false
      }
    }
    .alert("Microphone access is off", isPresented: Binding(
      get: { audioAlert != nil },
      set: {
        if !$0 {
          audioAlert = nil
        }
      }
    )) {
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
      guard canUnmute else {
        onBlocked?()
        return
      }
      if store.media.microphonePermission == .denied || store.media.microphonePermission == .restricted {
        audioAlert = .microphonePermission
        return
      }
      requestedUnmute = true
    } else {
      requestedUnmute = false
    }
    store.toggleMicrophone(spaceID: spaceID)
  }
}

struct GridLeaveButton: View {
  let store: GridRoomService
  let spaceID: Int64
  let diameter: CGFloat

  var body: some View {
    Button(role: .destructive) {
      store.leaveCurrentRoom(spaceID: spaceID)
    } label: {
      Image(systemName: "phone.down.fill")
        .font(.system(size: diameter * 0.38, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: diameter, height: diameter)
        .background(Color.red, in: Circle())
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
