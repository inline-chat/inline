import InlineGrid
import InlineKit
import InlineProtocol
import InlineUI
import SwiftUI

/// Discovery is deliberately separate from call ownership. A bounded avatar
/// preview must never decide which device owns the user's current call.
@MainActor
struct GridHomeEntryProjection {
  let isEligible: Bool
  let avatars: [GridAvatar]
  let activeCount: Int

  init(store: GridRoomService, spaceID: Int64?) {
    let homes = spaceID.map { selectedID in
      store.orderedHomeSpaces.filter { $0.spaceID == selectedID }
    } ?? store.orderedHomeSpaces
    isEligible = !homes.isEmpty
    activeCount = homes.reduce(0) { $0 + Int($1.activeAvatarCount) }
    var seen = Set<Int64>()
    var preview: [GridAvatar] = []
    for home in homes {
      for avatar in home.recentAvatars where seen.insert(avatar.user.id).inserted {
        preview.append(avatar)
        if preview.count == 4 {
          break
        }
      }
      if preview.count == 4 {
        break
      }
    }
    avatars = preview
  }

  var showsPill: Bool {
    isEligible && activeCount > 0 && !avatars.isEmpty
  }

  var showsMenuEntry: Bool {
    isEligible
  }
}

extension View {
  func gridHomeEntry(isVisible: Bool = true, onOpen: @escaping () -> Void) -> some View {
    modifier(GridHomeEntryModifier(isVisible: isVisible, onOpen: onOpen))
  }
}

private struct GridHomeEntryModifier: ViewModifier {
  let isVisible: Bool
  let onOpen: () -> Void
  private let store = GridIOSRuntime.shared.rooms

  func body(content: Content) -> some View {
    Group {
      if #available(iOS 26.0, *) {
        content.safeAreaBar(edge: .top, spacing: 0) {
          GridHomeBar(store: store, isVisible: isVisible, onOpen: onOpen)
        }
      } else {
        content.safeAreaInset(edge: .top, spacing: 0) {
          GridHomeBar(store: store, isVisible: isVisible, onOpen: onOpen)
        }
      }
    }
    // Returning from the background reloads Home through the app's Grid
    // wake hook, so this only covers first appearance.
    .task { await store.loadHome() }
  }
}

/// What Home shows above the chat list, most specific first.
@MainActor
private enum GridHomeBarState {
  /// This device is joining or carries the call: the room with its controls.
  case inCall(GridLocalCall, spaceID: Int64, room: GridRoom?)
  /// The call is elsewhere (usually the Mac) or paused here: bring it here.
  case elsewhere(GridCurrentCall, isMoving: Bool)
  /// Others are talking and the user is not: show who and where.
  case live(GridHomeEntryProjection)
  case hidden

  init(store: GridRoomService) {
    let call = GridLocalCall(store: store)
    switch call {
      case let .claiming(.join, spaceID, roomID):
        self = .inCall(call, spaceID: spaceID, room: roomID.flatMap { Self.room($0, spaceID: spaceID, store: store) })
        return
      case let .active(spaceID, roomID, _):
        self = .inCall(call, spaceID: spaceID, room: Self.room(roomID, spaceID: spaceID, store: store))
        return
      case .claiming:
        // Moving or resuming keeps the capsule the user tapped, now busy.
        if let current = store.currentCall {
          self = .elsewhere(current, isMoving: true)
          return
        }
      case let .paused(current), let .elsewhere(current):
        self = .elsewhere(current, isMoving: false)
        return
      case .none:
        break
    }
    let projection = GridHomeEntryProjection(store: store, spaceID: nil)
    self = projection.showsPill ? .live(projection) : .hidden
  }

  private static func room(_ roomID: Int64, spaceID: Int64, store: GridRoomService) -> GridRoom? {
    store.grid(spaceID: spaceID)?.rooms.first { $0.id == roomID }
  }
}

private struct GridHomeBar: View {
  let store: GridRoomService
  let isVisible: Bool
  let onOpen: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let state = isVisible ? GridHomeBarState(store: store) : .hidden
    Group {
      switch state {
        case let .inCall(call, spaceID, room):
          GridHomeInCallCapsule(store: store, call: call, spaceID: spaceID, room: room, onOpen: onOpen)
        case let .elsewhere(call, isMoving):
          GridHomeElsewhereCapsule(store: store, call: call, isMoving: isMoving, onOpen: onOpen)
        case let .live(projection):
          GridHomeLiveCapsule(projection: projection, onOpen: onOpen)
        case .hidden:
          EmptyView()
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.bottom, 6)
    .transition(.scale(scale: 0.9).combined(with: .opacity))
    .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: stateKey(state))
  }

  private func stateKey(_ state: GridHomeBarState) -> Int {
    switch state {
      case .inCall: 1
      case .elsewhere: 2
      case .live: 3
      case .hidden: 0
    }
  }
}

// MARK: - Capsules

private struct GridHomeLiveCapsule: View {
  let projection: GridHomeEntryProjection
  let onOpen: () -> Void

  var body: some View {
    Button(action: onOpen) {
      HStack(spacing: 6) {
        GridStackedAvatars(avatars: projection.avatars, size: 22)
        Text("\(projection.activeCount) in Grid")
          .font(.footnote.weight(.medium))
          .foregroundStyle(.secondary)
      }
      .padding(.leading, 4)
      .padding(.trailing, 10)
      .gridHomeCapsuleChrome(tint: nil)
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Grid, \(projection.activeCount) people talking")
    .accessibilityHint("Open voice rooms")
    .accessibilityIdentifier("gridHomePill")
  }
}

private struct GridHomeInCallCapsule: View {
  let store: GridRoomService
  let call: GridLocalCall
  let spaceID: Int64
  let room: GridRoom?
  let onOpen: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Others in the room; your own face adds nothing here.
  private var others: [GridAvatar] {
    Array((room?.avatars ?? []).filter { !$0.ownedByCurrentSession }.prefix(3))
  }

  var body: some View {
    HStack(spacing: 6) {
      Button(action: onOpen) {
        HStack(spacing: 6) {
          if !others.isEmpty {
            GridStackedAvatars(avatars: others, size: 22, levelForUser: { store.audioLevel(userID: $0) })
          }
          Text(room.map(GridRoomTitle.title(for:)) ?? String(localized: "Grid"))
            .font(.footnote.weight(.semibold))
            .lineLimit(1)
            .contentTransition(.opacity)
          // The Mac's connecting indicator, never "Connecting…" text.
          if call.isPending {
            GridConnectingDot()
          }
        }
        .padding(.leading, others.isEmpty ? 6 : 0)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityHint("Open Grid")

      GridMicrophoneButton(store: store, spaceID: spaceID, style: .compact)
      GridLeaveButton(store: store, spaceID: spaceID, style: .compact)
    }
    .padding(.leading, 4)
    .padding(.trailing, 3)
    .gridHomeCapsuleChrome(tint: nil)
    .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: call)
  }
}

private struct GridHomeElsewhereCapsule: View {
  let store: GridRoomService
  let call: GridCurrentCall
  let isMoving: Bool
  let onOpen: () -> Void

  /// Owned by this session but without local media, e.g. after a relaunch.
  private var isPausedHere: Bool { call.ownedByCurrentSession }

  var body: some View {
    HStack(spacing: 8) {
      Button(action: onOpen) {
        HStack(spacing: 5) {
          Image(systemName: isPausedHere ? "pause.fill" : GridCallOwner.systemImage(for: call))
            .font(.caption)
          Text(isPausedHere ? String(localized: "Call paused") : GridCallOwner.label(for: call))
            .font(.footnote.weight(.medium))
        }
        .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)

      if isMoving {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel(isPausedHere ? "Resuming" : "Moving call here")
      } else {
        Button(isPausedHere ? "Resume" : "Move here") { store.moveCallHere() }
          .font(.footnote.weight(.semibold))
          .foregroundStyle(Color.accentColor)
          .buttonStyle(.plain)
          .disabled(!store.callTransferEnabled)
          .accessibilityHint("Move your Grid call to this iPhone")
      }
    }
    .padding(.horizontal, 10)
    .gridHomeCapsuleChrome(tint: nil)
  }
}

// MARK: - Shared pieces

/// Overlapping avatars with an optional speaking ring.
struct GridStackedAvatars: View {
  let avatars: [GridAvatar]
  let size: CGFloat
  var levelForUser: ((Int64) -> Float)?

  var body: some View {
    HStack(spacing: -size * 0.3) {
      ForEach(avatars, id: \.user.id) { avatar in
        let speaking = (levelForUser?(avatar.user.id) ?? 0) > 0.01
        UserAvatar(user: InlineKit.User(from: avatar.user), size: size)
          .overlay { Circle().stroke(Color(.systemBackground), lineWidth: 1.5) }
          .overlay { Circle().stroke(speaking ? Color.green : .clear, lineWidth: 1.5).padding(-1) }
      }
    }
    .accessibilityHidden(true)
  }
}

private extension View {
  @ViewBuilder
  func gridHomeCapsuleChrome(tint: Color?) -> some View {
    let padded = padding(.vertical, 3).frame(minHeight: 32)
    if #available(iOS 26.0, *) {
      padded.glassEffect(tint.map { .regular.tint($0.opacity(0.15)) } ?? .regular, in: Capsule())
    } else {
      padded
        .background(.regularMaterial, in: Capsule())
        .background(tint.map { $0.opacity(0.12) } ?? .clear, in: Capsule())
    }
  }
}
