import InlineKit
import SwiftUI

struct RenameChatSheet: View {
  let peer: Peer

  @Environment(\.dismiss) private var dismiss
  @Environment(\.realtimeV2) private var realtimeV2

  @StateObject private var fullChat: FullChatViewModel
  @State private var title: String = ""
  @State private var emoji: String = ""
  @State private var showEmojiPicker = false
  @State private var isSaving = false
  @State private var didLoad = false

  @FocusState private var isTitleFocused: Bool

  private let emojis = [
    "👥", "💬", "🎯", "🛍️", "🛒", "💵", "🎧", "📚", "🍕", "📈",
    "⚙️", "🚧", "🏪", "🏡", "🎪", "🌴", "📁", "🤝", "🛖",
  ]

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
        Button(action: {
          showEmojiPicker.toggle()
        }) {
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
        .buttonStyle(PlainButtonStyle())
        .popover(isPresented: $showEmojiPicker) {
          emojiPickerView
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
      title = chat.title ?? "Chat"
      emoji = chat.emoji ?? ""
      didLoad = true
      isTitleFocused = true
    }
  }

  private var canSave: Bool {
    !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var emojiPickerView: some View {
    VStack(spacing: 12) {
      HStack {
        Text("Emoji")
          .font(.subheadline.weight(.semibold))
        Spacer()
        Button("Remove") {
          emoji = ""
          showEmojiPicker = false
        }
        .disabled(emoji.isEmpty)
      }

      Divider()

      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40))]) {
          ForEach(emojis, id: \.self) { emoji in
            Button(action: {
              self.emoji = emoji
              showEmojiPicker = false
            }) {
              Text(emoji)
                .font(.system(size: 24))
                .padding(8)
            }
            .buttonStyle(PlainButtonStyle())
          }
        }
      }
    }
    .padding()
    .frame(minWidth: 200, minHeight: 220, maxHeight: 320)
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
