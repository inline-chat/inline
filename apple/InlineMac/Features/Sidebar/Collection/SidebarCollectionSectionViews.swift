import AppKit
import SwiftUI

/// SwiftUI-hosted content for the collection's app-owned logical sections.
/// Geometry and identity remain collection-owned; this view owns only the
/// native-looking title and disclosure interaction.
struct SidebarCollectionSectionHeaderView: View {
  let title: String
  let isExpanded: Bool
  let topSpacing: CGFloat
  let cleanupMenu: SidebarOpenChatsCleanupMenu?
  let onToggle: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovered = false
  @State private var isDisclosureHovered = false
  @State private var presentedIsExpanded: Bool

  init(
    title: String,
    isExpanded: Bool,
    topSpacing: CGFloat,
    cleanupMenu: SidebarOpenChatsCleanupMenu?,
    onToggle: @escaping () -> Void
  ) {
    self.title = title
    self.isExpanded = isExpanded
    self.topSpacing = topSpacing
    self.cleanupMenu = cleanupMenu
    self.onToggle = onToggle
    _presentedIsExpanded = State(initialValue: isExpanded)
  }

  var body: some View {
    HStack(alignment: .center, spacing: 0) {
      Button(action: toggleImmediately) {
        Text(title)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(presentedIsExpanded ? "Collapse \(title)" : "Expand \(title)")
      .accessibilityAddTraits(.isHeader)

      if let cleanupMenu {
        cleanupMenu
          .opacity(isHovered ? 1 : 0)
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.1), value: isHovered)
      }

      Button(action: toggleImmediately) {
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(presentedIsExpanded ? 90 : 0))
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
          .opacity(isHovered ? 1 : 0)
          .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
              .fill(Color.primary.opacity(isDisclosureHovered ? 0.045 : 0))
          }
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.1), value: isHovered)
          .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: isDisclosureHovered)
      }
      .buttonStyle(.plain)
      .onHover { isDisclosureHovered = $0 }
      .accessibilityLabel(presentedIsExpanded ? "Collapse \(title)" : "Expand \(title)")
    }
    // Match the row identity axis and keep the larger disclosure target's
    // center on the same 19-point trailing axis as compact accessories.
    .padding(.leading, Theme.sidebarItemInnerSpacing + 8)
    .padding(.trailing, 7)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .padding(.top, topSpacing)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .onChange(of: isExpanded) { _, newValue in
      guard presentedIsExpanded != newValue else { return }
      withAnimation(disclosureAnimation) {
        presentedIsExpanded = newValue
      }
    }
  }

  private var disclosureAnimation: Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.1)
  }

  private func toggleImmediately() {
    withAnimation(disclosureAnimation) {
      presentedIsExpanded.toggle()
    }
    onToggle()
  }
}

struct SidebarOpenChatsCleanupMenu: View {
  @Binding var cleanupInterval: SidebarCleanupInterval
  let onCleanUp: () -> Void
  let onCloseAll: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovered = false

  var body: some View {
    Menu {
      Button(action: onCleanUp) {
        Label("Cleanup…", systemImage: "eraser.line.dashed")
      }

      Button(role: .destructive, action: onCloseAll) {
        Label("Close All", systemImage: "xmark.circle")
      }

      Divider()

      Menu {
        // Mirror SidebarViewOptionsMenuButton.Coordinator.cleanupItem() so
        // cleanup settings have the same ordering in both sidebar menus.
        cleanupIntervalButton(.never)

        Divider()

        Section("Close Open Chats After") {
          ForEach(SidebarCleanupInterval.allCases.filter { $0 != .never }) { interval in
            cleanupIntervalButton(interval)
          }
        }
      } label: {
        Label("Auto Cleanup", systemImage: "clock.arrow.circlepath")
      }
    } label: {
      Image(systemName: "eraser.line.dashed")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.tertiary)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
        .background {
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.primary.opacity(isHovered ? 0.045 : 0))
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: isHovered)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .onHover { isHovered = $0 }
    .help("Open Chats Cleanup")
    .accessibilityLabel("Open Chats Cleanup")
  }

  private func cleanupIntervalButton(_ interval: SidebarCleanupInterval) -> some View {
    Button {
      cleanupInterval = interval
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 1) {
          Text(interval.title)
          if interval == .never {
            Text(interval.detailText)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        if cleanupInterval == interval {
          Image(systemName: "checkmark")
        }
      }
    }
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
