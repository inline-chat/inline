import InlineKit
import InlineUI
import Logger
import MCEmojiPicker
import SwiftUI

struct CreateThread: View {
  @State private var animate: Bool = false
  @State private var isPresented: Bool = false
  @State private var name = ""
  @State private var selectedEmoji = ""
  @FocusState private var isFocused: Bool
  @FormState var formState

  @EnvironmentObject var nav: Navigation
  @Environment(\.appDatabase) var database
  @Environment(\.dismiss) var dismiss
  @EnvironmentObject var dataManager: DataManager

  var spaceId: Int64

  var body: some View {
    NavigationStack {
      List {
        Section {
          HStack {
            Button {
              isPresented.toggle()
            } label: {
              Circle()
                .fill(
                  LinearGradient(
                    colors: [
                      Color(.systemGray3).adjustLuminosity(by: 0.2),
                      Color(.systemGray5).adjustLuminosity(by: 0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                  )
                )
                .frame(width: 40, height: 40)
                .overlay {
                  if !selectedEmoji.isEmpty {
                    Text(selectedEmoji)
                      .font(.title3)
                  } else {
                    Image(systemName: "plus")
                      .font(.title3)
                      .foregroundColor(.secondary)
                  }
                }
            }
            .emojiPicker(
              isPresented: $isPresented,
              selectedEmoji: $selectedEmoji
            )
            TextField("Chat Title", text: $name)
              .focused($isFocused)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled(true)
              .onSubmit {
                submit()
              }
          }
        }
      }
      .themedListStyle()
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Text("Create Chat")
            .fontWeight(.bold)
            .themedPrimaryText()
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button(formState.isLoading ? "Creating..." : "Create") {
            submit()
          }
          .buttonStyle(.borderless)
          .disabled(name.isEmpty)
          .opacity(name.isEmpty ? 0.5 : 1)
        }
      }
      .onAppear {
        isFocused = true
      }
    }
    .themedSheet()
  }

  func submit() {
    Task {
      do {
        formState.startLoading()
        let threadId = try await dataManager.createThread(spaceId: spaceId, title: name, emoji: selectedEmoji)

        if let threadId {
          // First fetch dialogs to ensure the thread is in the list
          try await dataManager.getDialogs(spaceId: spaceId)

          formState.succeeded()
          dismiss()

          nav.push(.chat(peer: .thread(id: threadId)))
        }
      } catch {
        Log.shared.error("Failed to create thread", error: error)
      }
    }
  }
}
