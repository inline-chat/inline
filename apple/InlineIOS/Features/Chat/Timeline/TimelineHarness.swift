#if DEBUG
import InlineIOSUI
import InlineKit
import InlineTheme
import SwiftUI
import Translation
import UIKit

/// Debug builds only: `--chatlist-harness` opens the production chat screen with the timeline list
/// on the in-memory database that the same flag selects, seeded by `DebugChatFixture`, without
/// signing in.
///
/// - `--timeline-harness-open latest|unread|saved` picks the opening.
/// - `--timeline-harness-count N` seeds N messages (420).
/// - `--timeline-harness-collection` shows the collection view list instead, for comparison.
/// - `--timeline-harness-push` pushes the chat onto a stack, so it can be swiped back.
/// - `--timeline-legacy-rows` shows every message with the older view, to check the fallback rows.
/// - `--timeline-harness-uncached` keeps the history below the newest 30 messages "on the server",
///   so an unread opening has to fetch around its line. `--timeline-harness-fetch-ms N` sets the
///   fetch's latency (600), `--timeline-harness-fetch-fails` makes it fail after that.
/// - `--timeline-harness-hold-action reply|toggleAck|...` stands in for the user's hold action
///   (never stored), which shows the rows' actions button.
/// - `--timeline-harness-system-menu` stands in for VoiceOver: the list uses UIKit's menu.
struct TimelineHarnessRootView: View {
  static var isRequested: Bool { CommandLine.arguments.contains("--chatlist-harness") }

  static func argument(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
  }

  private static var opening: DebugChatFixture.Opening {
    argument("--timeline-harness-open").flatMap(DebugChatFixture.Opening.init(rawValue:)) ?? .latest
  }

  @State private var model = TimelineHarnessModel()
  @State private var path: [String] = []

  private static var pushes: Bool { CommandLine.arguments.contains("--timeline-harness-push") }

  var body: some View {
    NavigationStack(path: $path) {
      Group {
        if Self.pushes {
          List {
            Button("Open chat") { path = ["chat"] }
              .accessibilityIdentifier("harnessOpenChat")
          }
          .navigationTitle("Harness")
          // A pushed screen reads the model itself; it is not rebuilt when this view's state changes.
          .navigationDestination(for: String.self) { _ in TimelineHarnessScreen(model: model, opening: Self.opening) }
        } else {
          TimelineHarnessScreen(model: model, opening: Self.opening)
        }
      }
    }
    .task {
      await model.setUp(
        count: Self.argument("--timeline-harness-count").flatMap(Int.init) ?? 420, opening: Self.opening
      )
      if Self.pushes, path.isEmpty { path = ["chat"] }
    }
  }
}

/// The harness's fixture, observed by the chat screen wherever it is shown.
@MainActor
@Observable
final class TimelineHarnessModel {
  var fixture: DebugChatFixture?
  var initialState: MessagesProgressiveViewModel.InitialState?
  var failure: String?
  @ObservationIgnored let box = TimelineHarnessBox()

  func setUp(count: Int, opening: DebugChatFixture.Opening) async {
    guard fixture == nil else { return }
    do {
      let arguments = CommandLine.arguments
      let uncached = arguments.contains("--timeline-harness-uncached")
      let fixture = try DebugChatFixture(
        messageCount: count, remoteFloor: uncached ? max(1, count - 30) : nil, database: .shared, publisher: .shared
      )
      TimelineMessagesView.debugCurrentUserId = fixture.currentUserId
      if uncached {
        let latency = TimelineHarnessRootView.argument("--timeline-harness-fetch-ms").flatMap(Int.init) ?? 600
        let fails = arguments.contains("--timeline-harness-fetch-fails")
        TimelineMessagesView.debugLoadAround = { [weak fixture] messageId in
          guard let fixture else { return }
          if fails {
            try await Task.sleep(for: .milliseconds(latency))
            throw URLError(.notConnectedToInternet)
          }
          try await fixture.loadRemoteAround(messageId: messageId, latency: .milliseconds(latency))
        }
      }
      TimelineMessageMenu.debugHoldAction = TimelineHarnessRootView.argument("--timeline-harness-hold-action")
        .flatMap(MessageGestureAction.init(rawValue:))
      TimelineMessageMenu.debugPrefersSystemMenu = arguments.contains("--timeline-harness-system-menu")
      ComposeDebugOverrides.send = { send in
        Task { @MainActor in
          if let editing = send.editingMessageId {
            try? fixture.editFromComposer(messageId: editing, text: send.text)
          } else {
            try? await fixture.sendFromComposer(
              text: send.text, replyToMessageId: send.replyToMessageId, randomId: send.randomId,
              temporaryMessageId: send.temporaryMessageId
            )
          }
        }
      }
      initialState = try await fixture.initialState(for: opening)
      self.fixture = fixture
    } catch {
      failure = "Harness failed: \(error)"
    }
  }

  func run(_ step: (DebugChatFixture) throws -> Void) {
    guard let fixture else { return }
    do { try step(fixture) } catch { failure = "\(error)" }
  }

  func runAsync(_ step: @escaping (DebugChatFixture) async throws -> Void) {
    guard let fixture else { return }
    Task { try? await step(fixture) }
  }
}

private struct TimelineHarnessScreen: View {
  let model: TimelineHarnessModel
  let opening: DebugChatFixture.Opening
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Group {
      if let fixture = model.fixture, let initialState = model.initialState {
        TimelineHarnessChat(
          fixture: fixture, initialState: initialState, box: model.box,
          theme: ThemeManager.shared.snapshot(variant: ThemeAppearanceVariant(colorScheme: colorScheme))
        )
        .ignoresSafeArea()
      } else if let failure = model.failure {
        Text(failure).padding()
      } else {
        ProgressView()
      }
    }
    .navigationTitle("Timeline · \(opening.rawValue)")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu("Script") {
          Button("Receive") { model.run { try $0.receive() } }
          Button("Send and ack") { model.runAsync { try await $0.sendAndAcknowledge() } }
          Button("Edit newest") { model.run { try $0.edit() } }
          Button("Stream") { model.runAsync { try await $0.stream(steps: 120, every: .milliseconds(50)) } }
          Button("Delete newest") { model.run { try $0.deleteNewest() } }
          Button("Collapse history") { model.box.container?.setCollapsedMaxId(380) }
          Button("Translate newest") { model.run { try $0.translateNewest(language: UserLocale.getCurrentLanguage()) } }
          Button("Toggle translation") {
            guard let peer = model.fixture?.peer else { return }
            // Locally only: the harness is signed out, so the preference is never sent.
            let preferences = AppDatabase.shared.translationPreferences
            preferences.begin(!preferences.isEnabled(for: peer), for: peer, intent: UUID())
          }
          Button("Jump far up") {
            model.box.container?.focusMessage(40, requestRevision: Int.random(in: 1 ... 1_000_000), requiresExactMessage: false)
          }
          // VoiceOver stand-ins (the simulator cannot drive VoiceOver); results go to standard output.
          ForEach(["older", "newer", "dump", "focusTop", "focusBottom"], id: \.self) { action in
            Button("VoiceOver \(action)") {
              NotificationCenter.default.post(name: TimelineMessagesView.debugAccessibilityNotification, object: action)
            }
          }
        }
      }
    }
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
