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
/// - `--timeline-harness-prepare` (with push) reads the chat's window before each push, as the app does.
/// - `--timeline-legacy-rows` shows every message with the older view, to check the fallback rows.
/// - `--timeline-harness-uncached` keeps the history below the newest 30 messages "on the server",
///   so an unread opening has to fetch around its line. `--timeline-harness-fetch-ms N` sets the
///   fetch's latency (600), `--timeline-harness-fetch-fails` makes it fail after that.
/// - `--timeline-harness-hold-action reply|toggleAck|...` stands in for the user's hold action
///   (never stored), which shows the rows' actions button.
/// - `--timeline-harness-system-menu` stands in for VoiceOver: the list uses UIKit's menu.
/// - `--timeline-harness-stray-row` leaves history known only from just under the saved place up, with
///   one stray row cached across the hole below it, as paging back over a reply's quoted message does.
///   `--timeline-harness-rows-after N` also ends the known history N rows after it, as a jump's window.
/// - `--timeline-harness-focus ID` asks for a message as the chat opens.
/// - `--timeline-harness-dense` sends the fixture's messages 45 s apart in runs of 12, so long sender groups form.
/// - `--timeline-harness-preview` shows the chat as the chat list's preview does (no composer, no touches).
/// - `--timeline-harness-receive-every MS` receives a message every MS milliseconds, so one can arrive
///   mid-fling or mid-jump without a touch on the Script menu.
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

  /// With `--timeline-harness-prepare` the push waits for the chat's window read, as the app's router
  /// does, and is traced (`ChatOpen`); otherwise it pushes at once with the window read at setup.
  private func openChat() {
    guard CommandLine.arguments.contains("--timeline-harness-prepare"), let peer = model.fixture?.peer else {
      path = ["chat"]
      return
    }
    ChatOpenTrace.begin(peer: peer)
    Task { @MainActor in
      if let state = await ChatOpenPreparation.shared.state(for: peer) { model.initialState = state }
      ChatOpenTrace.prepared(peer: peer)
      path = ["chat"]
    }
  }

  var body: some View {
    NavigationStack(path: $path) {
      Group {
        if Self.pushes {
          List {
            Button("Open chat") { openChat() }
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
  @ObservationIgnored var statusNotice: String?
  @ObservationIgnored let box = TimelineHarnessBox()

  func setUp(count: Int, opening: DebugChatFixture.Opening) async {
    guard fixture == nil else { return }
    do {
      let arguments = CommandLine.arguments
      let uncached = arguments.contains("--timeline-harness-uncached")
      let fixture = try DebugChatFixture(
        messageCount: count, remoteFloor: uncached ? max(1, count - 30) : nil,
        dense: arguments.contains("--timeline-harness-dense"), database: .shared, publisher: .shared
      )
      TimelineMessagesView.debugCurrentUserId = fixture.currentUserId
      // Chat state is saved in user defaults and the fixture's peer is the same every launch, so a reply
      // left by one run would otherwise raise the composer for the next.
      ChatState.shared.clearReplyingMessageId(peer: fixture.peer)
      ChatState.shared.clearEditingMessageId(peer: fixture.peer)
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
      // Signed out, the harness's fixture user stands in as you, so your reactions draw as yours.
      MessageViewContent.debugCurrentUserId = fixture.currentUserId
      // Reactions stand in for the server: saved and published, then published again a round trip later.
      MessageViewActions.debugReactionMutation = { [weak fixture] _, emoji, messageId, _ in
        Task { @MainActor in try? await fixture?.toggleReaction(emoji: emoji, messageId: messageId) }
      }
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
      if arguments.contains("--timeline-harness-stray-row") {
        try fixture.strandSavedPlace(
          rowsAfter: TimelineHarnessRootView.argument("--timeline-harness-rows-after").flatMap(Int64.init)
        )
      }
      initialState = try await fixture.initialState(for: opening)
      self.fixture = fixture
      if let every = TimelineHarnessRootView.argument("--timeline-harness-receive-every").flatMap(Int.init) {
        Task { @MainActor [weak fixture] in
          while let fixture {
            try? await Task.sleep(for: .milliseconds(every))
            try? fixture.receive()
          }
        }
      }
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
          // The composer's edit and reply bars. The harness is signed out, so the menu has no Edit item.
          Button("Compose edit") {
            model.run { fixture in
              guard let id = try fixture.newestOutgoingMessageId() else { return }
              ChatState.shared.setEditingMessageId(peer: fixture.peer, id: id)
            }
          }
          Button("Compose reply") {
            model.run { fixture in
              guard let id = try fixture.newestOutgoingMessageId() else { return }
              ChatState.shared.setReplyingMessageId(peer: fixture.peer, id: id)
            }
          }
          Button("Compose clear") {
            guard let peer = model.fixture?.peer else { return }
            ChatState.shared.clearReplyingMessageId(peer: peer)
            ChatState.shared.clearEditingMessageId(peer: peer)
          }
          // The attachment strip coming and going (a picked photo, then its thumbnail's close button).
          Button("Compose photo") { model.box.container?.debugAddComposeImage() }
          Button("Compose remove photo") { model.box.container?.debugRemoveComposeImage() }
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
          // Jumps the collection view handled specially: a deleted message lands on its nearest
          // neighbour; a cleared one asked for exactly is unavailable; one not synced yet waits at the
          // live end for the update that brings it (Receive).
          Button("Jump to deleted 200") {
            model.run { try $0.delete(messageId: 200) }
            model.box.container?.focusMessage(200, requestRevision: Int.random(in: 1 ... 1_000_000), requiresExactMessage: false)
          }
          Button("Jump exact to 100") {
            model.box.container?.focusMessage(100, requestRevision: Int.random(in: 1 ... 1_000_000), requiresExactMessage: true)
          }
          Button("Jump to next incoming") {
            guard let id = model.fixture?.upcomingMessageId else { return }
            model.box.container?.focusMessage(id, requestRevision: Int.random(in: 1 ... 1_000_000), requiresExactMessage: false)
          }
          Button("Toggle status notice") {
            model.statusNotice = model.statusNotice == nil ? "Dana has notifications silenced" : nil
            model.box.container?.debugSetStatusNotice(model.statusNotice)
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
      peerId: fixture.peer, chatId: fixture.chatId, spaceId: nil, initialMessages: initialState,
      isPreview: CommandLine.arguments.contains("--timeline-harness-preview"), theme: theme,
      usesTimeline: !CommandLine.arguments.contains("--timeline-harness-collection")
    )
    box.container = view
    // A focus asked for as the chat opens, as a notification or search result opens it.
    if let id = TimelineHarnessRootView.argument("--timeline-harness-focus").flatMap(Int64.init) {
      view.focusMessage(id, requestRevision: 1, requiresExactMessage: false)
    }
    return view
  }

  func updateUIView(_ view: ChatContainerView, context _: Context) {
    view.applyTheme(theme)
  }
}
#endif
