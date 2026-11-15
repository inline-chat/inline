#if DEBUG
import InlineIOSUI
import InlineKit
import InlineTheme
import SwiftUI
import UIKit

/// Debug builds only: `--chatlist-harness` opens the production chat screen with the timeline list
/// on the in-memory database that the same flag selects, seeded by `DebugChatFixture`, without
/// signing in.
///
/// - `--timeline-harness-open latest|unread|saved` picks the opening.
/// - `--timeline-harness-count N` seeds N messages (420).
/// - `--timeline-harness-collection` shows the collection view list instead, for comparison.
struct TimelineHarnessRootView: View {
  static var isRequested: Bool { CommandLine.arguments.contains("--chatlist-harness") }

  private static func argument(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
  }

  private static var opening: DebugChatFixture.Opening {
    argument("--timeline-harness-open").flatMap(DebugChatFixture.Opening.init(rawValue:)) ?? .latest
  }

  @State private var fixture: DebugChatFixture?
  @State private var initialState: MessagesProgressiveViewModel.InitialState?
  @State private var failure: String?
  @State private var box = TimelineHarnessBox()
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    NavigationStack {
      Group {
        if let fixture, let initialState {
          TimelineHarnessChat(
            fixture: fixture, initialState: initialState, box: box,
            theme: ThemeManager.shared.snapshot(variant: ThemeAppearanceVariant(colorScheme: colorScheme))
          )
          .ignoresSafeArea()
        } else if let failure {
          Text(failure).padding()
        } else {
          ProgressView()
        }
      }
      .navigationTitle("Timeline · \(Self.opening.rawValue)")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Menu("Script") {
            Button("Receive") { run { try $0.receive() } }
            Button("Send and ack") { runAsync { try await $0.sendAndAcknowledge() } }
            Button("Edit newest") { run { try $0.edit() } }
            Button("Stream") { runAsync { try await $0.stream(steps: 120, every: .milliseconds(50)) } }
            Button("Delete newest") { run { try $0.deleteNewest() } }
            Button("Jump far up") { box.container?.focusMessage(40, requestRevision: Int.random(in: 1 ... 1_000_000), requiresExactMessage: false) }
          }
        }
      }
    }
    .task { await setUp() }
  }

  private func setUp() async {
    guard fixture == nil else { return }
    do {
      let count = Self.argument("--timeline-harness-count").flatMap(Int.init) ?? 420
      let fixture = try DebugChatFixture(messageCount: count, remoteFloor: nil, database: .shared, publisher: .shared)
      TimelineMessagesView.debugCurrentUserId = fixture.currentUserId
      ComposeDebugOverrides.send = { send in
        Task { @MainActor in
          if let editing = send.editingMessageId {
            try? fixture.editFromComposer(messageId: editing, text: send.text)
          } else {
            try? await fixture.sendFromComposer(text: send.text, replyToMessageId: send.replyToMessageId)
          }
        }
      }
      initialState = try await fixture.initialState(for: Self.opening)
      self.fixture = fixture
    } catch {
      failure = "Harness failed: \(error)"
    }
  }

  private func run(_ step: (DebugChatFixture) throws -> Void) {
    guard let fixture else { return }
    do { try step(fixture) } catch { failure = "\(error)" }
  }

  private func runAsync(_ step: @escaping (DebugChatFixture) async throws -> Void) {
    guard let fixture else { return }
    Task { try? await step(fixture) }
  }
}

@MainActor
final class TimelineHarnessBox {
  weak var container: ChatContainerView?
}

private struct TimelineHarnessChat: UIViewRepresentable {
  let fixture: DebugChatFixture
  let initialState: MessagesProgressiveViewModel.InitialState
  let box: TimelineHarnessBox
  let theme: IOSThemeSnapshot

  func makeUIView(context _: Context) -> ChatContainerView {
    let view = ChatContainerView(
      peerId: fixture.peer, chatId: fixture.chatId, spaceId: nil, initialMessages: initialState, theme: theme,
      usesTimeline: !CommandLine.arguments.contains("--timeline-harness-collection")
    )
    box.container = view
    return view
  }

  func updateUIView(_ view: ChatContainerView, context _: Context) {
    view.applyTheme(theme)
  }
}
#endif
