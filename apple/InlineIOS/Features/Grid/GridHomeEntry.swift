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
        if preview.count == 4 { break }
      }
      if preview.count == 4 { break }
    }
    avatars = preview
  }

  var showsPill: Bool { isEligible && activeCount > 0 && !avatars.isEmpty }
  var showsMenuEntry: Bool { isEligible && !showsPill }
}

extension View {
  func gridHomeEntry(
    isPresented: Binding<Bool>,
    spaceID: Int64? = nil,
    spaces: [InlineKit.Space] = [],
    isVisible: Bool = true
  ) -> some View {
    modifier(GridHomeEntryModifier(
      isPresented: isPresented,
      spaceID: spaceID,
      spaces: spaces,
      isVisible: isVisible
    ))
  }
}

private struct GridHomeEntryModifier: ViewModifier {
  @Binding var isPresented: Bool
  let spaceID: Int64?
  let spaces: [InlineKit.Space]
  let isVisible: Bool

  @AppStorage(ExperimentalFeatureFlags.gridIOSKey) private var isEnabled = false

  func body(content: Content) -> some View {
    Group {
      if isEnabled {
        content.modifier(GridEnabledHomeEntryModifier(
          isPresented: $isPresented,
          spaceID: spaceID,
          spaces: spaces,
          isVisible: isVisible
        ))
      } else {
        content
      }
    }
    .onChange(of: isEnabled) { wasEnabled, enabled in
      if wasEnabled && !enabled {
        isPresented = false
      }
    }
  }
}

private struct GridEnabledHomeEntryModifier: ViewModifier {
  @Binding var isPresented: Bool
  let spaceID: Int64?
  let spaces: [InlineKit.Space]
  let isVisible: Bool
  @Environment(\.scenePhase) private var scenePhase
  private let store = GridRuntime.shared.rooms

  func body(content: Content) -> some View {
    let projection = GridHomeEntryProjection(store: store, spaceID: nil)
    let showsPill = isVisible && projection.showsPill
    let presentation = Binding(
      get: { isPresented && projection.isEligible },
      set: { isPresented = $0 }
    )

    Group {
      if #available(iOS 26.0, *) {
        content.safeAreaBar(edge: .top, spacing: 0) {
          GridHomePill(
            avatars: projection.avatars,
            activeCount: projection.activeCount,
            isVisible: showsPill,
            onOpen: { isPresented = true }
          )
        }
      } else {
        content.safeAreaInset(edge: .top, spacing: 0) {
          GridHomePill(
            avatars: projection.avatars,
            activeCount: projection.activeCount,
            isVisible: showsPill,
            onOpen: { isPresented = true }
          )
        }
      }
    }
    .popover(isPresented: presentation, attachmentAnchor: .point(.top), arrowEdge: .top) {
      GridRoomsView(store: store, spaces: spaces, initialSpaceID: spaceID)
        .presentationCompactAdaptation(.sheet)
        .presentationDetents([.height(280), .medium, .large])
        .presentationDragIndicator(.visible)
    }
    .task { await store.loadHome() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        Task { await store.loadHome() }
      }
    }
    .onChange(of: projection.isEligible) { _, eligible in
      if !eligible { isPresented = false }
    }
  }
}

private struct GridHomePill: View {
  let avatars: [GridAvatar]
  let activeCount: Int
  let isVisible: Bool
  let onOpen: () -> Void

  var body: some View {
    if isVisible {
      Button(action: onOpen) {
        HStack(spacing: -6) {
          ForEach(avatars, id: \.user.id) { avatar in
            UserAvatar(user: InlineKit.User(from: avatar.user), size: 22)
              .overlay { Circle().stroke(.background, lineWidth: 1.5) }
          }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
        .contentShape(Capsule())
        .frame(minHeight: 44)
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Grid, \(activeCount) people present")
      .accessibilityHint("Open voice rooms")
      .accessibilityIdentifier("gridHomePill")
      .frame(maxWidth: .infinity)
    }
  }
}
