import InlineKit
import InlineMacUI
import InlineUI
import SwiftUI

struct SpacePickerOverlayView: View {
  private static let maxListHeight: CGFloat = 260

  let items: [SpaceHeaderItem]
  let activeTab: TabId
  let onSelect: (SpaceHeaderItem) -> Void
  let onCreateSpace: () -> Void

  private var shortcutByItemId: [String: String] {
    var dict: [String: String] = [:]
    dict[SpaceHeaderItem.home.id] = "⌘1"

    var i = 2
    for item in items where item.kind == .space {
      if i <= 9 {
        dict[item.id] = "⌘\(i)"
      }
      i += 1
    }
    return dict
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: SpacePickerOverlayStyle.cornerRadius, style: .continuous)
    let content = VStack(spacing: 8) {
      ScrollView {
        VStack(spacing: 0) {
          ForEach(pickerEntries) { entry in
            SpacePickerRow(
              entry: entry,
              activeTab: activeTab,
              shortcutLabel: shortcutLabel(for: entry),
              onSelect: onSelect,
              onCreateSpace: onCreateSpace
            )
          }
        }
      }
      .contentMargins(.vertical, 6, for: .scrollContent)
      .contentMargins(.horizontal, MainSidebar.innerEdgeInsets, for: .scrollContent)
      .frame(maxHeight: Self.maxListHeight)
    }
    .frame(width: SpacePickerOverlayStyle.preferredWidth)

    Group {
      if #available(macOS 26.0, *) {
        content.glassEffect(.regular, in: shape)
      } else {
        content
          .background(VisualEffectView(material: .popover, blendingMode: .withinWindow))
          .clipShape(shape)
      }
    }
    .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
    .shadow(
      color: Color.black.opacity(SpacePickerOverlayStyle.shadowOpacity),
      radius: SpacePickerOverlayStyle.shadowRadius,
      x: 0,
      y: SpacePickerOverlayStyle.shadowYOffset
    )
  }

  private var pickerEntries: [SpacePickerEntry] {
    var entries = items.map { SpacePickerEntry.space($0) }
    entries.append(.createSpace)
    return entries
  }

  private func shortcutLabel(for entry: SpacePickerEntry) -> String? {
    guard case let .space(item) = entry else { return nil }
    return shortcutByItemId[item.id]
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
  let shortcutLabel: String?
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
      if let shortcutLabel {
        Text(shortcutLabel)
          .font(.system(size: 12, weight: .semibold, design: .monospaced))
          .foregroundStyle(.tertiary)
          .frame(minWidth: 30, alignment: .trailing)
      }
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
        Color.primary.opacity(0.10)
      } else if isHovered {
        Color.primary.opacity(0.05)
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
