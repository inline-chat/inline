import SwiftUI
import UIKit

/// A date section whose pinned header turns into glass once content scrolls beneath it.
struct ChatInfoDateSection<Content: View>: View {
  let dateText: String
  let headerInsets: EdgeInsets
  @ViewBuilder let content: Content

  @State private var isPinned = false
  /// Frame edges change every scroll frame, so they live outside view state.
  @State private var edges = Edges()

  var body: some View {
    Section {
      Color.clear
        .frame(height: 0)
        .accessibilityHidden(true)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).minY } action: { minY in
          edges.contentMinY = minY
          updatePinned()
        }
      content
    } header: {
      ChatInfoDateBadge(dateText: dateText, isPinned: isPinned)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(headerInsets)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).maxY } action: { maxY in
          edges.headerMaxY = maxY
          updatePinned()
        }
    }
  }

  private func updatePinned() {
    let pinned = edges.contentMinY < edges.headerMaxY - 0.5
    if pinned != isPinned {
      isPinned = pinned
    }
  }

  private final class Edges {
    var contentMinY: CGFloat = 0
    var headerMaxY: CGFloat = 0
  }
}

/// Date header for chat info resource tabs, matching the chat's date separator when pinned.
struct ChatInfoDateBadge: View {
  let dateText: String
  var isPinned = false

  var body: some View {
    if #available(iOS 26.0, *) {
      label
        .foregroundStyle(isPinned ? .primary : .secondary)
        .glassEffect(isPinned ? .regular.interactive() : .identity, in: .capsule)
        .animation(.smooth(duration: 0.25), value: isPinned)
    } else {
      label
        .foregroundStyle(.secondary)
        .background(
          Capsule()
            .fill(Color(.systemBackground).opacity(0.95))
        )
    }
  }

  private var label: some View {
    Text(dateText)
      .font(.subheadline)
      .fontWeight(.medium)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .contentShape(Capsule())
      .accessibilityAddTraits(.isHeader)
  }
}
