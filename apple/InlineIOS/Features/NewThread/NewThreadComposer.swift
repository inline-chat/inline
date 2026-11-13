import Auth
import InlineKit
import Logger
import RealtimeV2
import SwiftUI

/// A compose box that starts a thread with its first message, the iOS counterpart of the
/// macOS empty-page composer (`AllChatsNewThreadCompose`). It is self-contained so it can
/// host the iPad empty detail page now and a New Thread sheet later.
///
/// Sending creates the thread locally, opens it in Inbox, queues the first message and hands
/// the new peer to `onCreated`. Agents, mentions and attachments are not part of this version.
@available(iOS 26.0, *)
struct NewThreadComposer: View {
  enum Style {
    /// A glass card pinned over content, as on the iPad empty detail page.
    case card
    /// The body of the New Thread sheet: no card chrome, focused on appear.
    case sheet
  }

  /// The space the composer starts in; `nil` is Home.
  let initialSpaceID: Int64?
  var style: Style = .card
  let onCreated: (Peer) -> Void

  @Environment(\.auth) private var auth
  @Environment(\.realtimeV2) private var realtimeV2
  @EnvironmentObject private var compactSpaceList: CompactSpaceList

  @State private var text = ""
  @State private var spaceID: Int64?
  @State private var isPublic = false
  @State private var isSending = false
  @State private var didApplyInitialSpace = false
  @FocusState private var isFocused: Bool

  private let log = Log.scoped("NewThreadComposer")

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      TextField("Start a new thread…", text: $text, axis: .vertical)
        .font(.body)
        .lineLimit(style == .sheet ? 3 ... 12 : 1 ... 8)
        .focused($isFocused)
        .disabled(isSending)
        .onKeyPress(.return, phases: .down) { press in
          // Hardware Return follows the compose setting; Shift-Return adds a line.
          guard INUserSettings.current.compose.sendWithReturnOnIPad,
                !press.modifiers.contains(.shift)
          else { return .ignored }
          submit()
          return .handled
        }
        .accessibilityIdentifier("newThreadComposerText")

      HStack(spacing: 8) {
        destinationMenu
        if spaceID != nil {
          visibilityButton
        }
        Spacer(minLength: 8)
        sendButton
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 14)
    .padding(.bottom, 10)
    .modifier(NewThreadComposerChrome(style: style))
    .onAppear {
      guard !didApplyInitialSpace else { return }
      didApplyInitialSpace = true
      spaceID = initialSpaceID
      if style == .sheet {
        isFocused = true
      }
    }
  }

  // MARK: - Controls

  private var destinationMenu: some View {
    Menu {
      Picker("Post In", selection: $spaceID) {
        Label("Home", systemImage: "house").tag(Int64?.none)
        ForEach(compactSpaceList.spaces) { space in
          Text(space.displayName).tag(Int64?.some(space.id))
        }
      }
    } label: {
      pill(
        title: selectedSpaceName ?? String(localized: "Home"),
        systemImage: spaceID == nil ? "house" : "square.stack"
      )
    }
    // A menu label takes the accent tint; keep both pills the same quiet color.
    .tint(.secondary)
    .accessibilityLabel("Post In")
    .accessibilityValue(selectedSpaceName ?? String(localized: "Home"))
  }

  private var visibilityButton: some View {
    Button {
      isPublic.toggle()
    } label: {
      pill(
        title: isPublic ? String(localized: "Public") : String(localized: "Private"),
        systemImage: isPublic ? "globe" : "lock"
      )
    }
    .buttonStyle(.plain)
    .accessibilityHint(isPublic
      ? "Everyone in the space can find this thread."
      : "Only people you add can see this thread.")
  }

  private var sendButton: some View {
    Button(action: submit) {
      Image(systemName: "arrow.up")
        .font(.system(size: 15, weight: .semibold))
        .frame(width: 32, height: 32)
        .foregroundStyle(.white)
        .background(Circle().fill(canSend ? Color.accentColor : Color(.systemGray3)))
    }
    .buttonStyle(.plain)
    .disabled(!canSend)
    .accessibilityLabel("Start Thread")
  }

  private func pill(title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
      .font(.subheadline.weight(.medium))
      .lineLimit(1)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 10)
      .frame(height: 30)
      .background(Capsule().fill(Color(.tertiarySystemFill)))
  }

  private var selectedSpaceName: String? {
    guard let spaceID else { return nil }
    return compactSpaceList.spaces.first { $0.id == spaceID }?.displayName
  }

  private var trimmedText: String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canSend: Bool {
    !trimmedText.isEmpty && !isSending
  }

  // MARK: - Submit

  private func submit() {
    guard canSend else { return }
    guard let currentUserID = auth.currentUserId else {
      ToastManager.shared.showToast(
        "You're signed out. Please log in again.",
        type: .error,
        systemImage: "exclamationmark.triangle"
      )
      return
    }

    let message = text
    let destinationSpaceID = spaceID
    // Home threads are always private, as on macOS.
    let threadIsPublic = destinationSpaceID != nil && isPublic
    isSending = true

    Task { @MainActor in
      var createdPeer: Peer?
      do {
        let chatID = try await realtimeV2.createThreadLocally(
          title: nil,
          placeholderTitle: Self.placeholderTitle(for: message),
          emoji: nil,
          isPublic: threadIsPublic,
          spaceId: destinationSpaceID,
          participants: [currentUserID]
        )
        let peer: Peer = .thread(id: chatID)
        createdPeer = peer
        // A new thread belongs to Inbox right away, matching macOS.
        await realtimeV2.sendQueued(
          .updateDialogOpen(peerId: peer, open: true, requiresChatCreated: true)
        )
        let admitted = await realtimeV2.sendQueuedIfAccepted(.sendMessage(
          text: message,
          peerId: peer,
          chatId: chatID
        )) != nil
        if !admitted {
          // Keep the words: they become the new thread's draft.
          _ = Drafts2.shared.updateText(peer: peer, text: message)
          ToastManager.shared.showToast(
            "The thread was created, but the message couldn't be sent. It was saved as a draft.",
            type: .error,
            systemImage: "exclamationmark.triangle"
          )
        }
        // The sheet is dismissed by `onCreated`; clearing it first flashed an empty composer.
        if style == .card {
          text = ""
        }
        isSending = false
        onCreated(peer)
      } catch {
        log.error("Failed to start a thread from the composer", error: error)
        isSending = false
        if let createdPeer {
          onCreated(createdPeer)
        } else {
          ToastManager.shared.showToast(
            "Couldn't start the thread. Please try again.",
            type: .error,
            systemImage: "exclamationmark.triangle"
          )
        }
      }
    }
  }

  /// Matches macOS: the first 60 characters of the message, whitespace collapsed.
  static func placeholderTitle(for text: String) -> String {
    let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !normalized.isEmpty else { return "Message" }
    return String(normalized.prefix(60))
  }
}

@available(iOS 26.0, *)
private struct NewThreadComposerChrome: ViewModifier {
  let style: NewThreadComposer.Style

  func body(content: Content) -> some View {
    switch style {
      case .card:
        content.glassEffect(.regular, in: .rect(cornerRadius: 24))
      case .sheet:
        content
    }
  }
}

/// New Thread on iPhone and iPad: the composer in a sheet. A created thread dismisses the
/// sheet and opens in the presenting context.
@available(iOS 26.0, *)
struct NewThreadComposerSheet: View {
  let initialSpaceID: Int64?
  let onCreated: (Peer) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      NewThreadComposer(initialSpaceID: initialSpaceID, style: .sheet) { peer in
        dismiss()
        onCreated(peer)
      }
      .frame(maxHeight: .infinity, alignment: .top)
      .navigationTitle("New Thread")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", systemImage: "xmark", role: .cancel) {
            dismiss()
          }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }
}

/// Identifies one New Thread sheet presentation.
struct NewThreadSheetRequest: Identifiable {
  let id = UUID()
  let spaceID: Int64?
}
