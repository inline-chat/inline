import Auth
import InlineKit
import InlineUI
import Logger
import SwiftUI

@MainActor
enum ExperimentalHomeNavigationPerformance {
  private struct PendingChatOpen {
    let span: PerformanceTrace.Span
    let startedAt: Date
  }

  private static var pendingChatOpens: [Peer: PendingChatOpen] = [:]

  static func beginChatOpen(peer: Peer, source: String) {
    if let replaced = pendingChatOpens.removeValue(forKey: peer) {
      replaced.span.end("result=replaced")
    }
    pendingChatOpens[peer] = PendingChatOpen(
      span: PerformanceTrace.begin(
        "HomeChatOpen",
        category: .home,
        "source=\(source)"
      ),
      startedAt: Date()
    )
  }

  static func completeChatOpen(peer: Peer) {
    guard let pending = pendingChatOpens.removeValue(forKey: peer) else { return }
    let durationMs = PerformanceTrace.elapsedMilliseconds(since: pending.startedAt)
    pending.span.end("duration_ms=\(durationMs)")
    PerformanceTrace.slowBreadcrumb(
      "iOS Home chat navigation was slow",
      category: "ios.home.navigation.chat",
      durationMs: durationMs,
      thresholdMs: 100
    )
  }

  static func measureTabSwitch(from: String, to: String, rows: Int) {
    let startedAt = Date()
    let span = PerformanceTrace.begin(
      "HomeTabSwitch",
      category: .home,
      "from=\(from) to=\(to) rows=\(rows)"
    )
    Task { @MainActor in
      await Task.yield()
      let durationMs = PerformanceTrace.elapsedMilliseconds(since: startedAt)
      span.end("duration_ms=\(durationMs)")
      PerformanceTrace.slowBreadcrumb(
        "iOS Home tab switch was slow",
        category: "ios.home.navigation.tab",
        durationMs: durationMs,
        thresholdMs: 100,
        data: ["from": from, "to": to, "rows": rows]
      )
    }
  }

  static func measureBackToHome(rows: Int) {
    let startedAt = Date()
    let span = PerformanceTrace.begin(
      "HomeBackNavigation",
      category: .home,
      "rows=\(rows)"
    )
    Task { @MainActor in
      await Task.yield()
      let durationMs = PerformanceTrace.elapsedMilliseconds(since: startedAt)
      span.end("duration_ms=\(durationMs)")
      PerformanceTrace.slowBreadcrumb(
        "iOS back navigation to Home was slow",
        category: "ios.home.navigation.back",
        durationMs: durationMs,
        thresholdMs: 100,
        data: ["rows": rows]
      )
    }
  }
}

@available(iOS 17.0, *)
struct ExperimentalMembersSheetView: View {
  let spaceId: Int64

  @Environment(Router.self) private var router
  @EnvironmentStateObject private var viewModel: SpaceFullMembersViewModel
  @State private var didRunInitialFetch = false

  init(spaceId: Int64) {
    self.spaceId = spaceId
    _viewModel = EnvironmentStateObject { env in
      SpaceFullMembersViewModel(db: env.appDatabase, spaceId: spaceId)
    }
  }

  var body: some View {
    NavigationStack {
      List {
        ForEach(viewModel.filteredMembers) { member in
          ExperimentalMemberRow(
            member: member,
            onMessage: {
              router.dismissSheet()
              router.openPrimaryDestination(.chat(peer: .user(id: member.userInfo.user.id)))
            }
          )
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
        }
      }
      .listStyle(.plain)
      .navigationTitle("Members")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            Task {
              await viewModel.refetchMembers()
            }
          } label: {
            if viewModel.isLoading {
              ProgressView()
            } else {
              Image(systemName: "arrow.clockwise")
            }
          }
          .accessibilityLabel("Refresh")
        }
      }
    }
    .task {
      guard !didRunInitialFetch else { return }
      didRunInitialFetch = true
      await viewModel.refetchMembers()
    }
  }
}

@available(iOS 17.0, *)
private struct ExperimentalMemberRow: View {
  let member: FullMemberItem
  let onMessage: () -> Void

  @Environment(\.colorScheme) private var colorScheme

  private var buttonFill: Color {
    colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.045)
  }

  private var borderColor: Color {
    colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.07)
  }

  var body: some View {
    HStack(spacing: 12) {
      UserAvatar(userInfo: member.userInfo, size: 34)

      Text(member.userInfo.user.displayName)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(.primary)
        .lineLimit(1)

      Spacer(minLength: 0)

      Button(action: onMessage) {
        Image(systemName: "bubble.left.and.bubble.right.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.primary)
          .frame(width: 34, height: 34)
          .background(buttonFill, in: Circle())
          .overlay(
            Circle().stroke(borderColor, lineWidth: 0.5)
          )
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Message")
    }
    .padding(.vertical, 6)
  }
}
