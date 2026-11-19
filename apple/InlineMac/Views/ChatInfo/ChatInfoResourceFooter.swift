import InlineKit
import SwiftUI

/// The end of a resource tab: loading, empty and error states, and the next-page trigger.
///
/// It keeps one height per mode so the list doesn't jump as states change: a tall block
/// while the tab has no rows (loading, empty, error) and a short strip under rows. The
/// spinner appears only after a short delay, so cached rows replace it without a flash.
/// While on screen under rows, it requests the next page whenever the tab goes idle with
/// more history, once per row count; a later idle at the same count shows "Load More".
struct ChatInfoResourceFooter: View {
  let state: ChatResourceLoadState
  let isEmpty: Bool
  let emptyMessage: String
  var systemImage = "tray"
  var itemCount = 0
  let loadMore: () async -> Void
  let retry: () async -> Void

  private static let spinnerDelay: Duration = .milliseconds(250)
  private static let emptyHeight: CGFloat = 180
  private static let stripHeight: CGFloat = 44

  @State private var showsSpinner = false
  @State private var autoLoadedCount: Int?

  init(
    state: ChatResourceLoadState,
    isEmpty: Bool,
    emptyMessage: String,
    systemImage: String = "tray",
    itemCount: Int = 0,
    loadMore: @escaping () async -> Void,
    retry: @escaping () async -> Void
  ) {
    self.state = state
    self.isEmpty = isEmpty
    self.emptyMessage = emptyMessage
    self.systemImage = systemImage
    self.itemCount = itemCount
    self.loadMore = loadMore
    self.retry = retry
  }

  var body: some View {
    Group {
      if isEmpty {
        emptyContent
          .frame(maxWidth: .infinity, minHeight: Self.emptyHeight)
      } else {
        stripContent
          .frame(maxWidth: .infinity, minHeight: Self.stripHeight)
      }
    }
    .task(id: isWaiting) {
      showsSpinner = false
      guard isWaiting else { return }
      try? await Task.sleep(for: Self.spinnerDelay)
      guard !Task.isCancelled else { return }
      withAnimation(.easeIn(duration: 0.15)) { showsSpinner = true }
    }
    .task(id: AutoLoadKey(state: state, itemCount: itemCount, isEmpty: isEmpty)) {
      guard !isEmpty, state == .idle, autoLoadedCount != itemCount else { return }
      autoLoadedCount = itemCount
      // Unstructured: this task is replaced as soon as the state changes, and cancelling
      // it would cancel the page it started.
      Task { await loadMore() }
    }
  }

  private var isWaiting: Bool {
    switch state {
      case .loading: true
      case .idle: isEmpty || autoLoadedCount != itemCount
      case .failed, .complete: false
    }
  }

  @ViewBuilder
  private var emptyContent: some View {
    switch state {
      case .complete:
        ChatInfoResourceMessage(systemImage: systemImage, message: emptyMessage)
      case .failed:
        ChatInfoResourceMessage(
          systemImage: "exclamationmark.triangle",
          message: String(localized: "Couldn’t load history.")
        ) {
          Button("Try Again") { Task { await retry() } }
            .controlSize(.small)
        }
      case .idle, .loading:
        spinner
    }
  }

  @ViewBuilder
  private var stripContent: some View {
    switch state {
      case .loading:
        spinner
      case .idle:
        if autoLoadedCount == itemCount {
          Button("Load More") { Task { await loadMore() } }
            .buttonStyle(.link)
            .controlSize(.small)
        } else {
          spinner
        }
      case .failed:
        HStack(spacing: 8) {
          Text("Couldn’t load more.")
            .foregroundStyle(.secondary)
          Button("Try Again") { Task { await retry() } }
            .buttonStyle(.link)
        }
        .font(.callout)
      case .complete:
        Color.clear
    }
  }

  private var spinner: some View {
    ProgressView()
      .controlSize(.small)
      .opacity(showsSpinner ? 1 : 0)
      .accessibilityLabel(String(localized: "Loading"))
  }

  private struct AutoLoadKey: Equatable {
    let state: ChatResourceLoadState
    let itemCount: Int
    let isEmpty: Bool
  }
}

/// An SF Symbol and one calm line, with an optional action under it.
struct ChatInfoResourceMessage<Action: View>: View {
  let systemImage: String
  let message: String
  @ViewBuilder var action: () -> Action

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 26, weight: .regular))
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      action()
    }
    .padding(.vertical, 24)
  }
}

extension ChatInfoResourceMessage where Action == EmptyView {
  init(systemImage: String, message: String) {
    self.init(systemImage: systemImage, message: message) { EmptyView() }
  }
}
