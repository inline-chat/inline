import InlineKit
import SwiftUI

struct RenameChatSheet: View {
  let peer: Peer

  @Environment(\.dismiss) private var dismiss
  @Environment(\.realtimeV2) private var realtimeV2

  @StateObject private var fullChat: FullChatViewModel
  @State private var title: String = ""
  @State private var isSaving = false
  @State private var didLoad = false

  @FocusState private var isTitleFocused: Bool

  init(peer: Peer, initialTitle: String? = nil) {
    self.peer = peer
    _fullChat = StateObject(wrappedValue: FullChatViewModel(db: AppDatabase.shared, peer: peer))
    _title = State(initialValue: initialTitle ?? "")
    _didLoad = State(initialValue: initialTitle != nil)
  }

  var body: some View {
    VStack(spacing: 16) {
      Text("Rename Thread")
        .font(.title3)
        .fontWeight(.semibold)

      TextField("Thread Title", text: $title)
        .textFieldStyle(.roundedBorder)
        .focused($isTitleFocused)
        .onSubmit { save() }

      HStack {
        Button("Cancel", role: .cancel) {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)

        Spacer()

        Button("Save") {
          save()
        }
        .disabled(!canSave || isSaving)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 360)
    .onAppear {
      isTitleFocused = true
    }
    .onReceive(fullChat.$chatItem) { item in
      guard !didLoad else { return }
      guard let chat = item?.chat else { return }
      title = chat.humanReadableTitle ?? "Untitled"
      didLoad = true
      isTitleFocused = true
    }
  }

  private var canSave: Bool {
    !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func save() {
    guard canSave, !isSaving else { return }
    guard let chatId = peer.asThreadId() else {
      dismiss()
      return
    }

    isSaving = true
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let realtimeV2 = realtimeV2

    Task {
      do {
        _ = try await realtimeV2.send(.updateChatInfo(
          chatID: chatId,
          title: trimmedTitle,
          emoji: nil
        ))
      } catch {
        await MainActor.run {
          ToastCenter.shared.showError("Couldn’t rename thread. Please try again.")
        }
      }
    }

    dismiss()
  }
}
