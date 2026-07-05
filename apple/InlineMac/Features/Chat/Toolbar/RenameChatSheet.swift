import InlineKit
import SwiftUI

struct RenameChatSheet: View {
  let peer: Peer

  @Environment(\.dismiss) private var dismiss
  @Environment(\.realtimeV2) private var realtimeV2

  @StateObject private var fullChat: FullChatViewModel
  @State private var title: String = ""
  @State private var emoji: String = ""
  @State private var isSaving = false
  @State private var didLoad = false

  @FocusState private var isTitleFocused: Bool

  init(peer: Peer) {
    self.peer = peer
    _fullChat = StateObject(wrappedValue: FullChatViewModel(db: AppDatabase.shared, peer: peer))
  }

  var body: some View {
    VStack(spacing: 16) {
      Text("Rename")
        .font(.title3)
        .fontWeight(.semibold)

      HStack {
        Text("Icon")
        Spacer()
        EmojiTextFieldPicker(
          emoji: $emoji,
          targetSize: CGSize(width: 28, height: 28),
          accessibilityLabel: "Chat icon"
        ) { emoji, _, _ in
          iconPickerLabel(emoji)
        }
      }

      TextField("Chat Title", text: $title)
        .textFieldStyle(.roundedBorder)
        .focused($isTitleFocused)
        .onSubmit { save() }

      HStack {
        Button("Cancel") {
          dismiss()
        }

        Spacer()

        Button(isSaving ? "Saving..." : "Save") {
          save()
        }
        .disabled(!canSave || isSaving)
      }
    }
    .padding(20)
    .frame(width: 360)
    .onReceive(fullChat.$chatItem) { item in
      guard !didLoad else { return }
      guard let chat = item?.chat else { return }
    title = chat.humanReadableTitle ?? "Untitled"
      emoji = chat.emoji ?? ""
      didLoad = true
      isTitleFocused = true
    }
  }

  private var canSave: Bool {
    !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  @ViewBuilder
  private func iconPickerLabel(_ emoji: String) -> some View {
    if !emoji.isEmpty {
      Text(emoji)
        .font(.title)
        .frame(width: 28, height: 28)
    } else {
      Image(systemName: "message.fill")
        .font(.body)
        .frame(width: 28, height: 28)
        .background(Circle().fill(Color.gray.opacity(0.2)))
    }
  }

  private func save() {
    guard canSave, !isSaving else { return }
    guard let chatId = peer.asThreadId() else {
      dismiss()
      return
    }

    isSaving = true
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)

    Task {
      do {
        _ = try await realtimeV2.send(.updateChatInfo(
          chatID: chatId,
          title: trimmedTitle,
          emoji: trimmedEmoji
        ))
        await MainActor.run {
          isSaving = false
          dismiss()
        }
      } catch {
        await MainActor.run {
          isSaving = false
        }
      }
    }
  }
}
