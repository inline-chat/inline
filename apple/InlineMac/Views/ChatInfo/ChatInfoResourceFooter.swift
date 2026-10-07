import InlineKit
import SwiftUI

/// The footer remains present when a page has no renderable cells.
struct ChatInfoResourceFooter: View {
  let state: ChatResourceLoadState
  let isEmpty: Bool
  let emptyMessage: String
  let loadMore: () async -> Void
  let retry: () async -> Void

  var body: some View {
    VStack(spacing: 8) {
      switch state {
        case .idle:
          if isEmpty {
            ProgressView()
            Text("Loading history…").foregroundStyle(.secondary)
          } else {
            Button("Load More") { Task { await loadMore() } }
          }
        case .loading:
          ProgressView()
          if isEmpty {
            Text("Loading history…").foregroundStyle(.secondary)
          }
        case .failed:
          Text("Couldn't load history.").foregroundStyle(.secondary)
          Button("Retry") { Task { await retry() } }
        case .complete:
          if isEmpty {
            Text(emptyMessage).foregroundStyle(.secondary)
          }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
  }
}
