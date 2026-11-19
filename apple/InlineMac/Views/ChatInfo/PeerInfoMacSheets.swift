import AppKit
import InlineKit
import InlineUI
import Logger
import RealtimeV2
import SwiftUI
import Translation

/// Every sheet and confirmation chat info can raise, kept out of its body.
struct ChatInfoPresentations: ViewModifier {
  @Binding var showVisibilityPicker: Bool
  @Binding var showTranslationOptions: Bool
  @Binding var showAddParticipants: Bool
  @Binding var showRemoveParticipantConfirmation: Bool
  @Binding var showRemoveGroupConfirmation: Bool
  @Binding var showEditThread: Bool
  @Binding var showBotAccess: Bool
  @Binding var selectedParticipantIds: Set<Int64>
  let participantPendingRemoval: UserInfo?
  let groupPendingRemoval: UserGroup?
  let peer: Peer
  let chat: Chat?
  let bot: UserInfo?
  let dependencies: AppDependencies?
  let participants: [UserInfo]
  let groupParticipants: [UserGroup]
  let canToggleVisibility: Bool
  let canEditInfo: Bool
  let onConfirmPrivate: (Set<Int64>) -> Void
  /// True for public.
  let onChooseVisibility: (Bool) -> Void
  let onRemoveParticipant: (UserInfo) -> Void
  let onRemoveGroup: (UserGroup) -> Void

  @State private var showMakePublicConfirmation = false

  func body(content: Content) -> some View {
    content
      .sheet(isPresented: $showVisibilityPicker) {
        if let chat, let spaceId = chat.spaceId, let dependencies {
          ChatVisibilityParticipantsSheet(
            spaceId: spaceId,
            selectedUserIds: $selectedParticipantIds,
            db: dependencies.database,
            isPresented: $showVisibilityPicker,
            onConfirm: onConfirmPrivate
          )
        }
      }
      .sheet(isPresented: $showTranslationOptions) {
        TranslationOptions(peer: peer)
      }
      .sheet(isPresented: $showAddParticipants) {
        if let chat, let dependencies {
          if let spaceId = chat.spaceId {
            AddParticipantsSheet(
              chatId: chat.id,
              spaceId: spaceId,
              currentParticipants: participants,
              currentGroupParticipants: groupParticipants,
              db: dependencies.database,
              isPresented: $showAddParticipants
            )
          } else {
            AddHomeParticipantsSheet(
              chatId: chat.id,
              currentUserId: dependencies.auth.currentUserId,
              currentParticipants: participants,
              db: dependencies.database,
              isPresented: $showAddParticipants
            )
          }
        }
      }
      .sheet(isPresented: $showEditThread) {
        if let chat {
          PeerInfoMacEditThreadSheet(
            chat: chat,
            canEditInfo: canEditInfo,
            canToggleVisibility: canToggleVisibility,
            onMakePrivate: {
              showEditThread = false
              onChooseVisibility(false)
            },
            onMakePublic: {
              showEditThread = false
              showMakePublicConfirmation = true
            }
          )
        }
      }
      .sheet(isPresented: $showBotAccess) {
        if let bot {
          BotAccessSheet(bot: bot)
        }
      }
      .confirmationDialog(
        "Make this thread public?",
        isPresented: $showMakePublicConfirmation
      ) {
        Button("Cancel", role: .cancel) {}
        Button("Make Public") { onChooseVisibility(true) }
      } message: {
        Text("Everyone in this space will be able to read and join it.")
      }
      .confirmationDialog(
        "Remove from this thread?",
        isPresented: $showRemoveParticipantConfirmation,
        presenting: participantPendingRemoval
      ) { participant in
        Button("Cancel", role: .cancel) {}
        Button("Remove", role: .destructive) { onRemoveParticipant(participant) }
      } message: { participant in
        Text("\(participant.user.shortDisplayName) will lose access unless a group or the space still gives it.")
      }
      .confirmationDialog(
        "Remove group access?",
        isPresented: $showRemoveGroupConfirmation,
        presenting: groupPendingRemoval
      ) { group in
        Button("Cancel", role: .cancel) {}
        Button("Remove", role: .destructive) { onRemoveGroup(group) }
      } message: { group in
        Text("Remove \(group.name) from this thread? Members may still have access directly, through the parent thread, or through another group.")
      }
  }
}

/// Edit a thread's name and icon, and see or change who can read it.
struct PeerInfoMacEditThreadSheet: View {
  let chat: Chat
  let canEditInfo: Bool
  let canToggleVisibility: Bool
  let onMakePrivate: () -> Void
  let onMakePublic: () -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.realtimeV2) private var realtimeV2
  @State private var title: String
  @State private var emoji: String
  @State private var isSaving = false
  @FocusState private var isTitleFocused: Bool

  init(
    chat: Chat,
    canEditInfo: Bool,
    canToggleVisibility: Bool,
    onMakePrivate: @escaping () -> Void,
    onMakePublic: @escaping () -> Void
  ) {
    self.chat = chat
    self.canEditInfo = canEditInfo
    self.canToggleVisibility = canToggleVisibility
    self.onMakePrivate = onMakePrivate
    self.onMakePublic = onMakePublic
    _title = State(initialValue: chat.humanReadableTitle ?? "")
    _emoji = State(initialValue: chat.emoji ?? "")
  }

  private var previewChat: Chat {
    var chat = chat
    chat.emoji = emoji.isEmpty ? nil : emoji
    chat.title = title
    return chat
  }

  private var trimmedTitle: String {
    title.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var hasChanges: Bool {
    trimmedTitle != (chat.humanReadableTitle ?? "") || emoji != (chat.emoji ?? "")
  }

  var body: some View {
    VStack(spacing: 18) {
      Text("Edit Thread")
        .font(.title3.weight(.semibold))

      VStack(spacing: 10) {
        EmojiTextFieldPicker(
          emoji: $emoji,
          targetSize: CGSize(width: 72, height: 72),
          isDisabled: !canEditInfo || isSaving,
          accessibilityLabel: "Thread icon"
        ) { _, _, _ in
          ChatIcon(peer: .chat(previewChat), size: 72)
        }
        .help("Choose an emoji for this thread")

        if !emoji.isEmpty, canEditInfo {
          Button("Remove Icon") { emoji = "" }
            .buttonStyle(.link)
            .font(.caption)
        }
      }

      Form {
        TextField("Name", text: $title)
          .focused($isTitleFocused)
          .disabled(!canEditInfo)
          .onSubmit { save() }

        if chat.spaceId != nil, chat.parentChatId == nil {
          LabeledContent("Visibility") {
            HStack(spacing: 8) {
              Label(
                chat.isPublic == true ? "Public" : "Private",
                systemImage: chat.isPublic == true ? "person.2" : "lock"
              )
              .foregroundStyle(.secondary)
              if canToggleVisibility {
                Button(chat.isPublic == true ? "Make Private…" : "Make Public…") {
                  if chat.isPublic == true { onMakePrivate() } else { onMakePublic() }
                }
              }
            }
          }
          Text(visibilityFootnote)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      .scrollDisabled(true)
      .frame(height: chat.spaceId != nil && chat.parentChatId == nil ? 150 : 70)

      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("Save") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canEditInfo || trimmedTitle.isEmpty || !hasChanges || isSaving)
      }
    }
    .padding(20)
    .frame(width: 400)
    .onAppear { isTitleFocused = true }
  }

  private var visibilityFootnote: String {
    if chat.isPublic == true {
      return "Everyone in this space can read and join this thread."
    }
    return canToggleVisibility
      ? "Only the people and groups you add can read this thread."
      : "Only the people and groups added can read this thread. The creator or a space admin can change this."
  }

  private func save() {
    guard canEditInfo, !trimmedTitle.isEmpty, hasChanges, !isSaving else { return }
    isSaving = true
    let titleChanged = trimmedTitle != (chat.humanReadableTitle ?? "")
    let emojiChanged = emoji != (chat.emoji ?? "")
    let chatId = chat.id
    let newTitle = trimmedTitle
    let newEmoji = emoji
    Task {
      do {
        _ = try await realtimeV2.send(.updateChatInfo(
          chatID: chatId,
          title: titleChanged ? newTitle : nil,
          emoji: emojiChanged ? newEmoji : nil
        ))
        await MainActor.run { dismiss() }
      } catch {
        Log.shared.error("Failed to update thread info", error: error)
        await MainActor.run {
          isSaving = false
          ToastCenter.shared.showError("Couldn’t save the thread. Try again.")
        }
      }
    }
  }
}
