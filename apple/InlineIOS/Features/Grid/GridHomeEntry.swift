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
  private let store = GridRuntime.shared.rooms

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
  /// This device carries the call: show the room with its own controls.
  case inCall(spaceID: Int64, room: GridRoom?)
  /// The call is owned elsewhere (usually the Mac): offer to move it here.
  case elsewhere(GridCurrentCall)
  /// Others are talking and the user is not: show who and where.
  case live(GridHomeEntryProjection)
  case hidden

  init(store: GridRoomService) {
    if let call = store.currentCall {
      let room = store.grid(spaceID: call.spaceID)?.rooms.first { $0.id == call.roomID }
      if call.ownedByCurrentSession {
        self = store.hasLocalAdmission ? .inCall(spaceID: call.spaceID, room: room) : .elsewhere(call)
        return
      }
      if store.callTransferEnabled {
        self = .elsewhere(call)
        return
      }
    }
    let projection = GridHomeEntryProjection(store: store, spaceID: nil)
    self = projection.showsPill ? .live(projection) : .hidden
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
        case let .inCall(spaceID, room):
          GridHomeInCallCapsule(store: store, spaceID: spaceID, room: room, onOpen: onOpen)
        case let .elsewhere(call):
          GridHomeElsewhereCapsule(store: store, call: call, onOpen: onOpen)
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
  let spaceID: Int64
  let room: GridRoom?
  let onOpen: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Others in the room; your own face adds nothing here.
  private var others: [GridAvatar] {
    Array((room?.avatars ?? []).filter { !$0.ownedByCurrentSession }.prefix(3))
  }

  var body: some View {
    // Like Telegram's call bar: flat grey while connecting, green once live.
    let link = GridCallLink(store: store)
    let tint: Color = link.isInactive ? .secondary : .green
    HStack(spacing: 6) {
      Button(action: onOpen) {
        HStack(spacing: 6) {
          if !others.isEmpty {
            GridStackedAvatars(avatars: others, size: 22, levelForUser: { store.audioLevel(userID: $0) })
          }
          Text(link.statusText ?? room.map(GridRoomTitle.title(for:)) ?? String(localized: "Grid"))
            .font(.footnote.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .contentTransition(.opacity)
        }
        .padding(.leading, others.isEmpty ? 6 : 0)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityHint("Open Grid")

      GridMicrophoneButton(store: store, spaceID: spaceID, style: .compact, onBlocked: onOpen)
      GridLeaveButton(store: store, spaceID: spaceID, diameter: 26)
    }
    .padding(.leading, 4)
    .padding(.trailing, 3)
    .gridHomeCapsuleChrome(tint: tint)
    .animation(reduceMotion ? nil : .linear(duration: 0.3), value: link)
  }
}

private struct GridHomeElsewhereCapsule: View {
  let store: GridRoomService
  let call: GridCurrentCall
  let onOpen: () -> Void

  /// Owned by this session but without local media, e.g. after a relaunch.
  private var isPausedHere: Bool { call.ownedByCurrentSession }

  private var label: String {
    if isPausedHere { return String(localized: "Call paused") }
    switch call.ownerClientType.lowercased() {
      case "macos": return String(localized: "On your Mac")
      case "ios": return String(localized: "On another iPhone")
      default: return String(localized: "On another device")
    }
  }

  var body: some View {
    HStack(spacing: 8) {
      Button(action: onOpen) {
        HStack(spacing: 5) {
          Image(systemName: isPausedHere ? "pause.fill"
            : call.ownerClientType.lowercased() == "macos" ? "laptopcomputer" : "iphone")
            .font(.caption)
          Text(label)
            .font(.footnote.weight(.medium))
        }
        .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)

      Button(isPausedHere ? "Resume" : "Move here") { store.moveCallHere() }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.green)
        .buttonStyle(.plain)
        .disabled(store.membershipMutationInFlight || !store.callTransferEnabled)
        .accessibilityHint("Move your Grid call to this iPhone")
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
