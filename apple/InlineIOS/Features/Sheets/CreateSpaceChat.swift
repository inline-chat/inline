import InlineKit
import InlineProtocol
import Logger
import MCEmojiPicker
import SwiftUI

struct CreateSpaceChat: View {
  @EnvironmentObject var compactSpaceList: CompactSpaceList
  @State private var isPresented = false
  @State private var selectedEmoji = ""
  @State private var chatTitle = ""
  @FocusState private var isTitleFocused: Bool
  @State private var isPublic = true
  @State private var selectedSpaceId: Int64?
  @State private var selectedPeople: Set<Int64> = []
  @FormState var formState

  @Environment(\.appDatabase) var db
  @Environment(\.realtime) var realtime
  @Environment(\.dismiss) private var dismiss

  @EnvironmentObject var nav: Navigation

  // Computed property to get space view model when needed
  private var spaceViewModel: FullSpaceViewModel? {
    guard let selectedSpaceId else { return nil }
    return FullSpaceViewModel(db: db, spaceId: selectedSpaceId)
  }

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
            .contentShape(Circle())
            .buttonStyle(.plain)
            .emojiPicker(
              isPresented: $isPresented,
              selectedEmoji: $selectedEmoji
            )
            TextField("Chat Title", text: $chatTitle)
              .focused($isTitleFocused)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled(true)
              .onSubmit {
                submit()
              }
          }
        }

        Section {
          Picker("Space", selection: $selectedSpaceId) {
            Text("Select Space").tag(nil as Int64?)
            ForEach(compactSpaceList.spaces) { space in
              Text(space.nameWithoutEmoji).tag(space.id as Int64?)
            }
          }
          .pickerStyle(.menu)
        }

        Section {
          Picker("Chat Type", selection: $isPublic) {
            Text("Public").tag(true)
            Text("Private").tag(false)
          }
          .pickerStyle(.menu)
        }

        if !isPublic, let spaceId = selectedSpaceId, let spaceViewModel {
          Section(header: Text("Invite People")) {
            ForEach(spaceViewModel.memberChats, id: \.id) { member in
              memberRow(member)
            }
          }
        }
      }
      .background(.clear)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel") {
            dismiss()
          }
          .buttonStyle(.borderless)
        }

        ToolbarItem(placement: .topBarTrailing) {
          Button(formState.isLoading ? "Creating..." : "Create") {
            submit()
          }
          .buttonStyle(.borderless)
          .disabled(chatTitle.isEmpty || selectedSpaceId == nil || (!isPublic && selectedPeople.isEmpty))
          .opacity((chatTitle.isEmpty || selectedSpaceId == nil || (!isPublic && selectedPeople.isEmpty)) ? 0.5 : 1)
        }
      }
      .navigationTitle("Create Chat")
      .onAppear {
        isTitleFocused = true
      }
      .onChange(of: selectedSpaceId) { _, _ in
        // Clear selected people when space changes
        selectedPeople.removeAll()
      }
    }
  }

  private func memberRow(_ member: SpaceChatItem) -> some View {
    HStack {
      Text(member.user?.fullName ?? "Unknown User")
      Spacer()
      if let userId = member.user?.id, selectedPeople.contains(userId) {
        Image(systemName: "checkmark")
          .foregroundColor(.blue)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture {
      guard let userId = member.user?.id else { return }
      if selectedPeople.contains(userId) {
        selectedPeople.remove(userId)
      } else {
        selectedPeople.insert(userId)
      }
    }
  }

  private func submit() {
    guard let selectedSpaceId else { return }

    Task {
      if chatTitle.isEmpty { return }
      do {
        formState.startLoading()
        let title = chatTitle
        let emoji = selectedEmoji.isEmpty ? nil : selectedEmoji
        let isPublic = isPublic
        let spaceId = selectedSpaceId
        let participants = isPublic ? [] : selectedPeople.map(\.self)

        // Use the transaction system instead of direct realtime call
        let transaction = TransactionCreateChat(
          title: title,
          emoji: emoji,
          isPublic: isPublic,
          spaceId: spaceId,
          participants: Array(participants)
        )

        Transactions.shared.mutate(transaction: .createChat(transaction))

        // For now, we'll wait a bit and then dismiss - in a real app you'd want to handle the success callback
        formState.succeeded()

        // Navigate to the created chat - we'll need to wait for the transaction to complete
        // For now, just dismiss
        dismiss()

      } catch {
        formState.failed(error: error.localizedDescription)
        Log.shared.error("Failed to create chat", error: error)
      }
    }
  }
}

#if DEBUG
#Preview {
  CreateSpaceChat()
    .environmentObject(Navigation())
    .environmentObject(CompactSpaceList(db: AppDatabase.shared))
    .previewsEnvironment(.populated)
}
#endif
