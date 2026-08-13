import AppKit
import SwiftUI

/// SwiftUI-hosted content for the collection's app-owned logical sections.
/// Geometry and identity remain collection-owned; this view owns only the
/// native-looking title and disclosure interaction.
struct SidebarCollectionSectionHeaderView: View {
  let title: String
  let isExpanded: Bool
  let onToggle: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovered = false

  var body: some View {
    HStack(alignment: .center, spacing: 6) {
      Text(title)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)

      Button(action: onToggle) {
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isExpanded)
          .frame(width: 18, height: 18)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .opacity(isHovered ? 1 : 0)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: isHovered)
      .accessibilityLabel(isExpanded ? "Collapse \(title)" : "Expand \(title)")
    }
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    // Chat rows use an eight-point full-width hover inset before their own
    // content padding. Match that visible leading edge instead of leaving
    // section titles stuck to the collection boundary.
    .padding(.leading, Theme.sidebarItemInnerSpacing + 8)
    .padding(.trailing, Theme.sidebarContentSideSpacing)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
