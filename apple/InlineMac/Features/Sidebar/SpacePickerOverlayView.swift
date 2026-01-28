import InlineKit
import InlineMacUI
import InlineUI
import SwiftUI

struct SpacePickerOverlayView: View {
  private static let cornerRadius: CGFloat = 12
  private static let maxListHeight: CGFloat = 260
  private static let preferredWidth: CGFloat = 240

  let items: [SpaceHeaderItem]
  let activeTab: TabId
  let onSelect: (SpaceHeaderItem) -> Void
  let onCreateSpace: () -> Void

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    let content = VStack(spacing: 8) {
      ScrollView {
        VStack(spacing: 0) {
          ForEach(pickerEntries) { entry in
            SpacePickerRow(entry: entry, activeTab: activeTab, onSelect: onSelect, onCreateSpace: onCreateSpace)
          }
        }
      }
      .contentMargins(.vertical, 6, for: .scrollContent)
      .contentMargins(.horizontal, MainSidebar.innerEdgeInsets, for: .scrollContent)
      .frame(maxHeight: Self.maxListHeight)
    }
    .frame(width: Self.preferredWidth)
    .background(shape.fill(tint))

    Group {
      if #available(macOS 26.0, *) {
        content.glassEffect(.regular, in: shape)
      } else {
        content
      }
    }
    .compositingGroup()
    .shadow(
      color: Color.black.opacity(SpacePickerOverlayStyle.shadowOpacity),
      radius: SpacePickerOverlayStyle.shadowRadius,
      x: 0,
      y: SpacePickerOverlayStyle.shadowYOffset
    )
  }

  private var tint: Color {
    let opacity = colorScheme == .dark ? 0.14 : 0.18
    return colorScheme == .dark ? Color.black.opacity(opacity) : Color.white.opacity(opacity)
  }

  private var pickerEntries: [SpacePickerEntry] {
    var entries = items.map { SpacePickerEntry.space($0) }
    entries.append(.createSpace)
    return entries
  }
}

private enum SpacePickerEntry: Identifiable, Hashable {
  case space(SpaceHeaderItem)
  case createSpace

  var id: String {
    switch self {
      case let .space(item):
        item.id
      case .createSpace:
        "create-space"
    }
  }
}

private struct SpacePickerRow: View {
  let entry: SpacePickerEntry
  let activeTab: TabId
  let onSelect: (SpaceHeaderItem) -> Void
  let onCreateSpace: () -> Void

  @State private var isHovered = false

  var body: some View {
    HStack(spacing: MainSidebar.iconTrailingPadding) {
      iconView
      Text(title)
        .font(Font(MainSidebar.font))
        .foregroundColor(textColor)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .frame(height: MainSidebar.itemHeight)
    .padding(.horizontal, MainSidebar.innerEdgeInsets)
    .background(backgroundView)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .onHover { hovering in
      isHovered = hovering
    }
    .onTapGesture {
      handleTap()
    }
  }

  private var iconView: some View {
    Group {
      switch entry {
        case let .space(item):
          switch item.kind {
            case .home:
              Image(systemName: "house.fill")
                .font(.system(size: Theme.sidebarTitleIconSize * 0.7, weight: .semibold))
                .foregroundColor(textColor)
                .frame(width: Theme.sidebarTitleIconSize, height: Theme.sidebarTitleIconSize)
            case .space:
              if let space = item.space {
                SpaceAvatar(space: space, size: Theme.sidebarTitleIconSize)
              }
          }
        case .createSpace:
          Image(systemName: "plus")
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(textColor)
            .frame(width: MainSidebar.iconSize, height: MainSidebar.iconSize)
      }
    }
  }

  private var backgroundView: some View {
    Group {
      if isActive {
        Color(nsColor: Theme.windowContentBackgroundColor)
      } else if isHovered {
        Color.white.opacity(0.2)
      } else {
        Color.clear
      }
    }
  }

  private var textColor: Color {
    Color(nsColor: .labelColor)
  }

  private var isActive: Bool {
    guard case let .space(item) = entry else { return false }
    return item.matches(spaceId: activeTab.spaceId, isHome: activeTab == .home)
  }

  private var title: String {
    switch entry {
      case let .space(item):
        return item.title
      case .createSpace:
        return "Create space"
    }
  }

  private func handleTap() {
    switch entry {
      case let .space(item):
        onSelect(item)
      case .createSpace:
        onCreateSpace()
    }
  }
}
