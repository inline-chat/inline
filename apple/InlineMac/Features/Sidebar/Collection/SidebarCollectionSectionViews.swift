import AppKit
import SwiftUI

/// One non-overshooting motion curve for every sidebar disclosure affordance.
/// The short duration keeps collection reflow responsive while the strong
/// ease-out removes the rigid midpoint acceleration of `easeInOut`.
enum SidebarDisclosureMotion {
  static let duration: TimeInterval = 0.18
  static let minimumRetargetDuration: TimeInterval = 0.08
  static let controlPoint1 = (x: 0.2, y: 0.8)
  static let controlPoint2 = (x: 0.2, y: 1.0)

  static var animation: Animation {
    .timingCurve(
      controlPoint1.x,
      controlPoint1.y,
      controlPoint2.x,
      controlPoint2.y,
      duration: duration
    )
  }
}

/// Shared SwiftUI/AppKit geometry for logical section headers. The collection
/// owns a full-width row, so these values are measured from that row boundary.
enum SidebarSectionHeaderMetrics {
  static let leadingInset = Theme.sidebarItemInnerSpacing + 8
  static let trailingInset: CGFloat = 7
  static let controlSize: CGFloat = 24
}

/// SwiftUI-hosted content for the collection's app-owned logical sections.
/// Geometry and identity remain collection-owned; this view owns only the
/// native-looking title and disclosure interaction.
struct SidebarCollectionSectionHeaderView: View {
  let title: String
  let initialIsExpanded: Bool
  let hostState: SidebarCollectionRowHostState?
  let topSpacing: CGFloat
  let cleanupMenu: SidebarOpenChatsCleanupMenu?
  let onToggle: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovered = false

  private var isExpanded: Bool {
    hostState?.sectionIsExpanded ?? initialIsExpanded
  }

  var body: some View {
    HStack(alignment: .center, spacing: 0) {
      Button(action: onToggle) {
        Text(title)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isExpanded ? "Collapse \(title)" : "Expand \(title)")
      .accessibilityAddTraits(.isHeader)

      if let cleanupMenu {
        cleanupMenu
          .opacity(isHovered ? 1 : 0)
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.1), value: isHovered)
      }

      Button(action: onToggle) {
        SidebarSectionChevronIcon(
          isExpanded: isExpanded,
          animates: !reduceMotion
        )
          .opacity(isExpanded && isHovered == false ? 0 : 1)
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.1), value: isExpanded)
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.1), value: isHovered)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isExpanded ? "Collapse \(title)" : "Expand \(title)")
    }
    // Match the row identity axis and keep the larger disclosure target's
    // center on the same 19-point trailing axis as compact accessories.
    .padding(.leading, SidebarSectionHeaderMetrics.leadingInset)
    .padding(.trailing, SidebarSectionHeaderMetrics.trailingInset)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .padding(.top, topSpacing)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
  }
}

/// A plain chronological label. Unlike the app-owned lane headers, timeline
/// headers have no disclosure state, hover treatment, or interaction.
struct SidebarCollectionTimelineHeaderView: View {
  let title: String

  var body: some View {
    Text(title)
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .padding(.leading, SidebarSectionHeaderMetrics.leadingInset)
      .padding(.trailing, SidebarSectionHeaderMetrics.trailingInset)
      .accessibilityAddTraits(.isHeader)
  }
}

struct SidebarOpenChatsCleanupMenu: View {
  let onCleanUp: () -> Void
  let onCloseAll: () -> Void

  var body: some View {
    Menu {
      Button(action: onCleanUp) {
        Label("Cleanup…", systemImage: "eraser.line.dashed")
      }

      Button(role: .destructive, action: onCloseAll) {
        Label("Close All", systemImage: "xmark.circle")
      }
    } label: {
      SidebarSectionCleanupIcon()
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .help("Open Chats Cleanup")
    .accessibilityLabel("Open Chats Cleanup")
  }
}

struct SidebarSectionChevronIcon: View {
  let isExpanded: Bool
  let animates: Bool

  var body: some View {
    Image(systemName: "chevron.right")
      .font(.system(size: 9, weight: .semibold))
      .foregroundStyle(.tertiary)
      .rotationEffect(.degrees(isExpanded ? 90 : 0))
      .animation(animates ? SidebarDisclosureMotion.animation : nil, value: isExpanded)
      .frame(width: 24, height: 24)
      .contentShape(Rectangle())
  }
}

struct SidebarSectionCleanupIcon: View {
  var body: some View {
    Image(systemName: "eraser.line.dashed")
      .font(.system(size: 10, weight: .medium))
      .foregroundStyle(.tertiary)
      .frame(width: 24, height: 24)
      .contentShape(Rectangle())
  }
}

struct SidebarCollectionPinDropGuideView: View {
  let dimsInstruction: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 4) {
      Image(systemName: "pin")
        .font(.system(size: 12, weight: .semibold))
      Text("Move here to pin")
        .font(.system(size: 11, weight: .medium))
    }
    .foregroundStyle(Color(nsColor: Theme.accentColor))
    .opacity(dimsInstruction ? 0.28 : 1)
    .animation(
      reduceMotion ? nil : .easeOut(duration: 0.1),
      value: dimsInstruction
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background {
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(Color(nsColor: Theme.accentColor).opacity(0.045))
        .overlay {
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(
              Color(nsColor: Theme.accentColor).opacity(0.48),
              style: StrokeStyle(lineWidth: 1, dash: [5, 4])
            )
        }
        .padding(.horizontal, Theme.sidebarItemInnerSpacing)
        .padding(.vertical, 6)
    }
    .accessibilityLabel("Move here to pin")
  }
}
