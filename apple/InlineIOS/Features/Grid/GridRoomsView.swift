import AVKit
import InlineAudioPlayback
import InlineGrid
import InlineKit
import InlineProtocol
import InlineRTC
import InlineUI
import SwiftUI
import UIKit

struct GridRoomsView: View {
  let store: GridRoomService
  let spaces: [InlineKit.Space]
  @State private var selectedSpaceID: Int64?
  @State private var selectedShare: GridScreenShareSelection?
  @State private var presentedFailure: GridActionFailure?
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

  private var actionFailure: GridActionFailure? {
    let hasConnectionFailure = store.media.connectionState == .failed
    let connectionError = hasConnectionFailure ? store.media.lastConnectionError : nil
    let audioError: String?
    if case let .failed(message) = store.media.audioState {
      audioError = message
    } else {
      audioError = nil
    }
    let storeError = store.membershipMutationInFlight ? nil : store.lastError
    let errors = [storeError, connectionError, audioError].compactMap { $0 }
    let hasMediaFailure = hasConnectionFailure || audioError != nil || store.media.providerCircuitOpen
    let audio = InlineAudioSession.shared
    if audio.isQuarantined && (store.hasLocalAdmission || !errors.isEmpty)
      || errors.contains(InlineAudioSessionError.quarantined.localizedDescription) {
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
    NavigationStack {
      VStack(spacing: 16) {
        if let spaceID = effectiveSpaceID {
          GridRoomCollection(store: store, spaceID: spaceID, onViewShare: { avatar, share in
            guard let identity = store.mediaSessionIdentity else { return }
            selectedShare = GridScreenShareSelection(
              mediaSessionIdentity: identity,
              participantIdentity: share.participantIdentity,
              publicationID: share.publicationID,
              displayName: InlineKit.User(from: avatar.user).displayName
            )
          })

          GridCurrentRoomControls(store: store, spaceID: store.currentCall?.spaceID ?? spaceID)
          if !store.callTransferEnabled {
            Text("Grid is unavailable")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done", systemImage: "xmark") { dismiss() }
            .labelStyle(.iconOnly)
            .accessibilityLabel("Close Grid")
        }
      }
      .task(id: effectiveSpaceID) {
        if let spaceID = effectiveSpaceID { await store.load(spaceID: spaceID) }
      }
      .onChange(of: actionFailure, initial: true) { _, failure in
        if let failure {
          presentedFailure = failure
          store.clearLastError()
        }
      }
      .alert(presentedFailure?.title ?? "Unable to update Grid", isPresented: Binding(
        get: { presentedFailure != nil },
        set: { if !$0 { presentedFailure = nil } }
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
              if let spaceID = effectiveSpaceID { await store.load(spaceID: spaceID) }
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
    .frame(idealWidth: 360, idealHeight: 280)
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

  var canRetryAudio: Bool { self == .audio || self == .retirementPending }
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
            } else {
              Text(title(for: home.spaceID))
            }
          }
        }
      } label: {
        HStack(spacing: 4) {
          Text(selectedSpaceID.map(title(for:)) ?? String(localized: "Grid"))
            .lineLimit(1)
          Image(systemName: "chevron.down").font(.caption2)
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

private struct GridRoomCollection: View {
  let store: GridRoomService
  let spaceID: Int64
  let onViewShare: (GridAvatar, InlineRTCScreenShare) -> Void

  var body: some View {
    ScrollView {
      if let grid = store.grid(spaceID: spaceID) {
        GridRoomFlowLayout(spacing: 12) {
          ForEach(grid.rooms, id: \.id) { room in
            GridRoomCapsule(store: store, room: room, onViewShare: onViewShare)
          }
          Button {
            store.createAndJoin(spaceID: spaceID)
          } label: {
            Image(systemName: "plus")
              .font(.body.weight(.medium))
              .foregroundStyle(.secondary)
              .frame(width: 62, height: 62)
              .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
          }
          .buttonStyle(.plain)
          .disabled(store.membershipMutationInFlight || !store.callTransferEnabled
            || store.currentCall?.ownedByCurrentSession == false)
          .accessibilityLabel("Create and join a Grid room")
        }
        .padding(.top, 8)
      } else if store.failedLoadSpaceIDs.contains(spaceID) {
        Button("Try Again") { Task { await store.load(spaceID: spaceID) } }
          .frame(maxWidth: .infinity, minHeight: 80)
      } else {
        ProgressView().frame(maxWidth: .infinity, minHeight: 80)
      }
    }
  }
}

private struct GridRoomCapsule: View {
  let store: GridRoomService
  let room: GridRoom
  let onViewShare: (GridAvatar, InlineRTCScreenShare) -> Void

  private var isCurrent: Bool {
    store.currentCall?.roomID == room.id && store.currentCall?.ownedByCurrentSession == true
      && store.hasLocalAdmission
  }

  var body: some View {
    Group {
      if isCurrent {
        GridRoomAvatars(store: store, avatars: room.avatars, isCurrent: true, onViewShare: onViewShare)
      } else {
        Button {
          if store.currentCall?.roomID == room.id {
            store.moveCallHere()
          } else {
            store.join(roomID: room.id)
          }
        } label: {
          GridRoomAvatars(store: store, avatars: room.avatars, isCurrent: false, onViewShare: onViewShare)
        }
        .buttonStyle(.plain)
        .disabled(store.membershipMutationInFlight || !store.callTransferEnabled
          || (room.locked && store.currentCall?.roomID != room.id)
          || (store.currentCall?.ownedByCurrentSession == false && store.currentCall?.roomID != room.id))
        .accessibilityLabel(joinAccessibilityLabel)
      }
    }
    .padding(8)
    .frame(minWidth: 62, minHeight: 62)
    .background(
      isCurrent ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045),
      in: RoundedRectangle(cornerRadius: 16)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 16)
        .stroke(isCurrent ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.07), lineWidth: 1)
    }
    .overlay(alignment: .top) {
      if room.hasTitle {
        Text(room.title)
          .font(.caption2)
          .lineLimit(1)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(.regularMaterial, in: Capsule())
          .offset(y: -8)
      }
    }
    .overlay(alignment: .bottomTrailing) {
      if room.locked {
        Image(systemName: "lock.fill")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .padding(5)
          .accessibilityLabel("Locked room")
      }
    }
  }

  private var joinAccessibilityLabel: String {
    if let call = store.currentCall, call.roomID == room.id {
      return call.ownedByCurrentSession ? String(localized: "Resume Grid here") : String(localized: "Move Grid here")
    }
    return room.hasTitle ? String(localized: "Join \(room.title)") : String(localized: "Join Grid room")
  }
}

private struct GridRoomAvatars: View {
  let store: GridRoomService
  let avatars: [GridAvatar]
  let isCurrent: Bool
  let onViewShare: (GridAvatar, InlineRTCScreenShare) -> Void

  var body: some View {
    HStack(spacing: 4) {
      ForEach(avatars.prefix(4), id: \.user.id) { avatar in
        GridRoomAvatar(store: store, avatar: avatar, isCurrent: isCurrent, onViewShare: onViewShare)
      }
      if avatars.count > 4 {
        GridRoomAvatarOverflow(
          store: store,
          avatars: Array(avatars.dropFirst(4)),
          isCurrent: isCurrent,
          onViewShare: onViewShare
        )
      }
    }
    .frame(minWidth: 44, minHeight: 44)
  }
}

private struct GridRoomAvatarOverflow: View {
  let store: GridRoomService
  let avatars: [GridAvatar]
  let isCurrent: Bool
  let onViewShare: (GridAvatar, InlineRTCScreenShare) -> Void

  var body: some View {
    Menu {
      ForEach(avatars, id: \.user.id) { avatar in
        if isCurrent {
          ForEach(store.screenShares(avatar: avatar)) { share in
            Button {
              onViewShare(avatar, share)
            } label: {
              Label("View \(InlineKit.User(from: avatar.user).displayName)’s screen", systemImage: "rectangle.on.rectangle")
            }
          }
        }
      }
    } label: {
      Text("+\(avatars.count)")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 30, height: 44)
    }
    .disabled(!isCurrent || !avatars.contains { !store.screenShares(avatar: $0).isEmpty })
    .accessibilityLabel("\(avatars.count) more people")
  }
}

private struct GridRoomAvatar: View {
  let store: GridRoomService
  let avatar: GridAvatar
  let isCurrent: Bool
  let onViewShare: (GridAvatar, InlineRTCScreenShare) -> Void

  var body: some View {
    let level = isCurrent ? store.audioLevel(userID: avatar.user.id) : 0
    let shares = isCurrent ? store.screenShares(avatar: avatar) : []

    UserAvatar(user: InlineKit.User(from: avatar.user), size: 42)
      .padding(2)
      .overlay {
        Circle().stroke(level > 0.01 ? Color.green : .clear, lineWidth: 1.5)
      }
      .overlay(alignment: .bottomTrailing) {
        if !shares.isEmpty {
          Menu {
            ForEach(shares) { share in
              Button("View Screen", systemImage: "rectangle.on.rectangle") {
                onViewShare(avatar, share)
              }
            }
          } label: {
            Image(systemName: "rectangle.on.rectangle.fill")
              .font(.caption2)
              .padding(4)
              .background(.regularMaterial, in: Circle())
              .frame(minWidth: 44, minHeight: 44, alignment: .bottomTrailing)
          }
          .accessibilityLabel("View \(InlineKit.User(from: avatar.user).displayName)’s screen")
        }
      }
      .accessibilityLabel(InlineKit.User(from: avatar.user).displayName)
  }
}

struct GridCurrentRoomControls: View {
  let store: GridRoomService
  let spaceID: Int64

  var body: some View {
    if let call = store.currentCall, call.spaceID == spaceID {
      if call.ownedByCurrentSession && store.hasLocalAdmission {
        GridLocalAudioControls(store: store, spaceID: spaceID)
      } else {
        HStack(spacing: 16) {
          Button(call.ownedByCurrentSession ? "Resume here" : "Move here", systemImage: "arrow.down.to.line") {
            store.moveCallHere()
          }
          .buttonStyle(.bordered)
          .disabled(store.membershipMutationInFlight || !store.callTransferEnabled)
          .accessibilityHint("Move your active Grid call to this device")

          if store.membershipMutationInFlight {
            Button("Cancel") { store.withdrawLocalAdmission() }
          } else if call.ownedByCurrentSession {
            Button(role: .destructive) {
              store.leaveCurrentRoom(spaceID: spaceID)
            } label: {
              Image(systemName: "phone.down.fill").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Leave Grid room")
          }
        }
      }
    } else if store.membershipMutationInFlight {
      Button("Cancel") { store.withdrawLocalAdmission() }
        .accessibilityLabel("Cancel joining Grid")
    }
  }
}

private struct GridLocalAudioControls: View {
  private enum AudioAlert: Equatable {
    case microphonePermission
    case outputRoute
  }

  let store: GridRoomService
  let spaceID: Int64
  private let audio = InlineAudioSession.shared
  @State private var requestedUnmute = false
  @State private var audioAlert: AudioAlert?
  @Environment(\.openURL) private var openURL

  private var canUnmute: Bool {
    guard !store.media.isAudioSafetyPaused,
          let roomID = store.currentCall?.roomID,
          let room = store.grid(spaceID: spaceID)?.rooms.first(where: { $0.id == roomID })
    else { return false }
    return room.avatars.count > 1
  }

  var body: some View {
    VStack(spacing: 8) {
      if store.media.isAudioSafetyPaused {
        Button("Resume Audio", systemImage: "play.fill") { store.retryAudio() }
          .buttonStyle(.bordered)
          .disabled(store.membershipMutationInFlight)
      }

      audioControls
    }
    .frame(maxWidth: .infinity)
    .onChange(of: store.media.microphonePermission) { _, permission in
      if requestedUnmute && (permission == .denied || permission == .restricted) {
        audioAlert = .microphonePermission
        requestedUnmute = false
      } else if permission == .authorized {
        requestedUnmute = false
      }
    }
    .alert(alertTitle, isPresented: Binding(
      get: { audioAlert != nil },
      set: { if !$0 { audioAlert = nil } }
    )) {
      if audioAlert == .microphonePermission {
        Button("Open Settings") {
          if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
        Button("Cancel", role: .cancel) {}
      } else {
        Button("OK", role: .cancel) {}
      }
    }
  }

  private var audioControls: some View {
    HStack(spacing: 16) {
      Button {
        if !store.media.isMicrophoneEnabled {
          if store.media.microphonePermission == .denied || store.media.microphonePermission == .restricted {
            audioAlert = .microphonePermission
            return
          }
          requestedUnmute = true
        } else {
          requestedUnmute = false
        }
        store.toggleMicrophone(spaceID: spaceID)
      } label: {
        Image(systemName: store.media.isMicrophoneEnabled ? "mic.fill" : "mic.slash.fill")
          .frame(width: 44, height: 44)
          .background(.thinMaterial, in: Circle())
      }
      .disabled((!canUnmute || store.membershipMutationInFlight) && !store.media.isMicrophoneEnabled)
      .accessibilityLabel(store.media.isMicrophoneEnabled
        ? String(localized: "Mute microphone")
        : String(localized: "Unmute microphone"))

      if audio.supportsReceiverRouting {
        Button {
          let preferred = !audio.isSpeakerOutputActive
          Task { @MainActor in
            do {
              try await audio.setSpeakerPreferred(preferred)
            } catch {
              if !(error is CancellationError) { audioAlert = .outputRoute }
            }
          }
        } label: {
          Image(systemName: audio.isSpeakerOutputActive ? "speaker.wave.2.fill" : "speaker.wave.2")
            .frame(width: 44, height: 44)
            .background(.thinMaterial, in: Circle())
        }
        .accessibilityLabel(audio.isSpeakerOutputActive
          ? String(localized: "Turn off speaker")
          : String(localized: "Use speaker"))
        .accessibilityValue(audio.currentRouteName)
      }

      GridNativeAudioRoutePicker(routeName: audio.currentRouteName)
        .frame(width: 44, height: 44)

      Button(role: .destructive) {
        store.leaveCurrentRoom(spaceID: spaceID)
      } label: {
        Image(systemName: "phone.down.fill")
          .frame(width: 44, height: 44)
          .background(.thinMaterial, in: Circle())
      }
      .accessibilityLabel("Leave Grid room")
    }
    .buttonStyle(.plain)
  }

  private var alertTitle: LocalizedStringKey {
    audioAlert == .microphonePermission ? "Microphone access is off" : "Unable to change audio output"
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
      if x > 0 && x + size.width > width {
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
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > bounds.minX && x + size.width > bounds.maxX {
        y += rowHeight + spacing
        x = bounds.minX
        rowHeight = 0
      }
      view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}
