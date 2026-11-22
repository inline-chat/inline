import InlineKit
import SwiftUI

/// The end of a resource tab: first-load progress, the empty state, and below loaded
/// rows a fixed-height slot for paging progress or a retry.
///
/// The slot keeps one height whatever it shows, so rows above never jump when a page
/// starts or finishes. While it is within a screen of the viewport it asks for the next
/// page whenever the row count or load state changes, which also fills pages too short
/// to scroll. Visibility comes from geometry, not `onAppear`, because the tab sits in
/// the page's lazy stack and may not be lazy itself.
@available(iOS 17.0, *)
struct ChatInfoResourceFooter: View {
  struct Empty {
    let systemImage: String
    let message: LocalizedStringKey
  }

  let state: ChatResourceLoadState
  let rowCount: Int
  let empty: Empty
  let onReachEnd: () -> Void
  let retry: () -> Void

  @State private var isNearViewport = false

  private struct Trigger: Equatable {
    let state: ChatResourceLoadState
    let rowCount: Int
    let isNearViewport: Bool
  }

  var body: some View {
    Group {
      if rowCount == 0 {
        emptyContent
          .frame(maxWidth: .infinity, minHeight: 220)
      } else {
        pagingContent
          .frame(maxWidth: .infinity, minHeight: 64)
      }
    }
    .animation(.smooth(duration: 0.2), value: state)
    .onGeometryChange(for: Bool.self) { proxy in
      // The scroll view's visible rect in this view's coordinates; the footer starts at y = 0.
      guard let visible = proxy.bounds(of: .scrollView) else { return true }
      return visible.maxY + visible.height > 0
    } action: { isNear in
      isNearViewport = isNear
    }
    .task(id: Trigger(state: state, rowCount: rowCount, isNearViewport: isNearViewport)) {
      if isNearViewport { onReachEnd() }
    }
  }

  @ViewBuilder
  private var emptyContent: some View {
    switch state {
      case .idle, .loading:
        ProgressView()
          .accessibilityLabel("Loading")
      case .failed:
        ChatInfoResourceEmptyState(
          systemImage: "exclamationmark.triangle",
          message: "Couldn’t load history",
          retry: retry
        )
      case .complete:
        ChatInfoResourceEmptyState(systemImage: empty.systemImage, message: empty.message)
    }
  }

  @ViewBuilder
  private var pagingContent: some View {
    switch state {
      case .loading:
        ProgressView()
          .accessibilityLabel("Loading more")
      case .failed:
        HStack(spacing: 12) {
          Text("Couldn’t load more")
            .foregroundStyle(.secondary)
          Button("Retry", action: retry)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .font(.subheadline)
      case .idle, .complete:
        Color.clear
          .accessibilityHidden(true)
    }
  }
}

/// A calm empty or error state: a symbol, one short line, and an optional retry.
struct ChatInfoResourceEmptyState: View {
  let systemImage: String
  let message: LocalizedStringKey
  var retry: (() -> Void)?

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 28))
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
      Text(message)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      if let retry {
        Button("Retry", action: retry)
          .buttonStyle(.bordered)
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 36)
    .accessibilityElement(children: .combine)
  }
}
