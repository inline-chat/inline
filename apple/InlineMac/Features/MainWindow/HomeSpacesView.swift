import AppKit
import InlineKit
import InlineUI
import Logger
import SwiftUI

// NOTE: Currently unused in the new macOS UI (home no longer shows spaces).
struct HomeSpacesView: View {
  @Environment(\.dependencies) private var dependencies
  @EnvironmentObject private var data: DataManager
  @EnvironmentStateObject private var home: HomeViewModel

  @State private var showAll: Bool = false
  @State private var hoveredSpaceId: Int64?

  init() {
    _home = EnvironmentStateObject { env in
      HomeViewModel(db: env.appDatabase)
    }
  }

  private var visibleSpaces: [HomeSpaceItem] {
    guard !showAll else { return home.spaces }
    return Array(home.spaces.prefix(5))
  }

  var body: some View {
    GeometryReader { proxy in
      ScrollView(.vertical) {
        VStack {
          Spacer(minLength: 0)

          VStack(spacing: 16) {
            Text("Your spaces")
              .font(.system(size: 16, weight: .semibold))
              .foregroundStyle(.primary)

            if home.spaces.isEmpty {
              emptyState
            } else {
              spacesList
            }
          }
          .frame(maxWidth: 360)

          Spacer(minLength: 0)
        }
        .frame(minHeight: proxy.size.height)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
      }
    }
    .task {
      do {
        try await data.getSpaces()
      } catch {
        Log.shared.error("Failed to get spaces", error: error)
      }
    }
  }

  private var spacesList: some View {
    spacesListContent
      .frame(maxWidth: .infinity, alignment: .center)
  }

  private var spacesListContent: some View {
    VStack(spacing: 6) {
      ForEach(visibleSpaces, id: \.id) { spaceItem in
        HomeSpaceRow(
          space: spaceItem.space,
          isHovered: hoveredSpaceId == spaceItem.space.id,
          onHover: { isHovering in
            hoveredSpaceId = isHovering ? spaceItem.space.id : nil
          },
          onSelect: {
            dependencies?.nav2?.openSpace(spaceItem.space)
          }
        )
      }

      if home.spaces.count > 5, !showAll {
        showMoreButton
      }
    }
  }

  @ViewBuilder
  private var showMoreButton: some View {
    Button("Show more") {
      withAnimation(.easeInOut(duration: 0.18)) {
        showAll = true
      }
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .padding(.top, 6)
  }

  private var emptyState: some View {
    VStack(spacing: 10) {
      Image(systemName: "building.2")
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(.secondary)

      Text("No spaces yet")
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.primary)

      Text("Create a space to get started.")
        .font(.system(size: 12, weight: .regular))
        .foregroundStyle(.secondary)

      Button("Create space") {
        dependencies?.nav2?.navigate(to: .createSpace)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
    .multilineTextAlignment(.center)
    .padding(.top, 6)
  }
}

private struct HomeSpaceRow: View {
  let space: Space
  let isHovered: Bool
  let onHover: (Bool) -> Void
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      rowContent
    }
    .buttonStyle(.plain)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(isHovered ? Color(nsColor: NSColor.controlAccentColor).opacity(0.12) : .clear)
    )
    .onHover(perform: onHover)
  }

  private var rowContent: some View {
    HStack(spacing: 12) {
      SpaceAvatar(space: space, size: 32)

      Text(space.displayName)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.primary)

      Spacer(minLength: 0)
    }
    .padding(.vertical, 6.4)
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
