import InlineKit
import InlineProtocol
import Logger
import MCEmojiPicker
import SwiftUI

public struct CreateChatIOSView: View {
  @State private var isPresented: Bool = false
  @State private var chatTitle: String = ""
  @State private var selectedEmoji: String = ""
  @State private var isPublic: Bool = true
  @State private var selectedPeople: Set<Int64> = []
  @FocusState private var isTitleFocused: Bool
  @FormState var formState

  @StateObject private var spaceViewModel: FullSpaceViewModel

  @Environment(\.appDatabase) var db
  @Environment(\.realtime) var realtime
  @Environment(\.dismiss) private var dismiss

  @EnvironmentObject var nav: Navigation

  let spaceId: Int64

  public init(spaceId: Int64) {
    self.spaceId = spaceId
    _spaceViewModel = StateObject(wrappedValue: FullSpaceViewModel(db: AppDatabase.shared, spaceId: spaceId))
  }

  public var body: some View {
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
          Picker("Chat Type", selection: $isPublic) {
            Text("Public").tag(true)
            Text("Private").tag(false)
          }
          .pickerStyle(.menu)
        }
        if !isPublic {
          Section(header: Text("Invite People")) {
            ForEach(spaceViewModel.memberChats, id: \.id) { member in
              memberRow(member)
            }
          }
        }
      }
      .themedListStyle()
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button(formState.isLoading ? "Creating..." : "Create") {
            submit()
          }
          .buttonStyle(.borderless)
          .disabled(chatTitle.isEmpty || (!isPublic && selectedPeople.isEmpty))
          .opacity((chatTitle.isEmpty || (!isPublic && selectedPeople.isEmpty)) ? 0.5 : 1)
        }
      }
      .navigationTitle("Create Chat")
      .onAppear {
        isTitleFocused = true
      }
    }
    .themedSheet()
  }

  private func memberRow(_ member: SpaceChatItem) -> some View {
    HStack {
      Text(member.user?.fullName ?? "Unknown User")
        .themedPrimaryText()
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
    Task {
      if chatTitle.isEmpty { return }
      do {
        formState.startLoading()
        let title = chatTitle
        let emoji = selectedEmoji.isEmpty ? nil : selectedEmoji
        let isPublic = isPublic
        let spaceId = spaceId
        let participants = isPublic ? [] : selectedPeople.map(\.self)

        let result = try await realtime.invokeWithHandler(
          .createChat,
          input: .createChat(.with {
            $0.title = title
            $0.spaceID = spaceId
            if let emoji { $0.emoji = emoji }
            $0.isPublic = isPublic
            $0.participants = participants.map { userId in InputChatParticipant.with { $0.userID = Int64(userId) } }
          })
        )

        if case let .createChat(createChatResult) = result {
          formState.succeeded()
          nav.push(.chat(peer: .thread(id: createChatResult.chat.id)))
          dismiss()
        }
      } catch {
        formState.failed(error: error.localizedDescription)
        Log.shared.error("Failed to create chat", error: error)
      }
    }
  }
}

#if DEBUG
#Preview {
  CreateChatIOSView(spaceId: 1)
    .environmentObject(Navigation())
    .previewsEnvironment(.populated)
}
#endif
