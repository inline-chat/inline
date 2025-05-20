import InlineKit
import InlineProtocol
import SwiftUI

public struct CreateChatView: View {
  @Environment(\.appDatabase) var db
  @Environment(\.realtime) var realtime
  @Environment(\.dismiss) private var dismiss

  @FormState var formState

  private let spaceId: Int64
  let onChatCreated: (Int64) -> Void

  @State private var chatTitle = ""
  @State private var selectedEmoji: String? = nil
  @State private var isPublic = true
  @State private var showEmojiPicker = false
  @State private var selectedPeople: Set<Int64> = []

  @FocusState private var isTitleFocused: Bool

  // Sample emoji collection
  let emojis = ["👥", "💬", "🎯", "🛍️", "🛒", "💵", "🎧", "📚", "🍕", "📈", "⚙️", "🚧", "🏪", "🏡", "🎪", "🌴", "📁", "🤝", "🛖"]

  // Space view model
  @StateObject private var spaceViewModel: FullSpaceViewModel

  public init(spaceId: Int64, onChatCreated: @escaping (Int64) -> Void) {
    self.spaceId = spaceId
    self.onChatCreated = onChatCreated
    _spaceViewModel = StateObject(wrappedValue: FullSpaceViewModel(db: AppDatabase.shared, spaceId: spaceId))
  }

  public var body: some View {
    mainForm
      .formStyle(.grouped)
      .padding()
      .scrollContentBackground(.hidden)
      .frame(width: 480, height: 600)
      .navigationTitle("Create Chat")
  }

  private var mainForm: some View {
    Form {
      chatDetailsSection
      if !isPublic {
        invitePeopleSection
      }
      createButtonSection
    }
  }

  private var chatDetailsSection: some View {
    Section(header: Text("New Chat")) {
      titleTextField
      iconPicker
      visibilityPicker
    }
  }

  private var titleTextField: some View {
    TextField(
      "Title",
      text: $chatTitle,
      prompt: Text("Enter chat title")
    )
    .textFieldStyle(.automatic)
    .font(.body)
    .focused($isTitleFocused)
    .onAppear { isTitleFocused = true }
  }

  private var iconPicker: some View {
    HStack {
      Text("Icon")
      Spacer()
      Button(action: {
        showEmojiPicker.toggle()
      }) {
        if let selectedEmoji {
          Text(selectedEmoji)
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
        #if os(iOS)
        .presentationCompactAdaptation(.popover)
        #endif
      }
    }
  }

  private var emojiPickerView: some View {
    ScrollView {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 40))]) {
        ForEach(emojis, id: \.self) { emoji in
          Button(action: {
            selectedEmoji = emoji
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
    .padding()
    .frame(minWidth: 200, minHeight: 200, maxHeight: 300)
  }

  private var visibilityPicker: some View {
    Picker("Visibility", selection: $isPublic) {
      Text("Public").tag(true)
      Text("Private").tag(false)
    }
    .pickerStyle(SegmentedPickerStyle())
  }

  private var invitePeopleSection: some View {
    Section(header: Text("Invite People")) {
      List {
        ForEach(spaceViewModel.memberChats, id: \.id) { member in
          memberRow(member)
        }
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

  private var createButtonSection: some View {
    Section {
      Button(action: submit) {
        HStack {
          Spacer()
          Text("Create Chat")
          Spacer()
        }
      }
      .disabled(chatTitle.isEmpty || (!isPublic && selectedPeople.isEmpty))
    }
  }

  // MARK: Methods

  private func submit() {
    Task {
      if chatTitle.isEmpty {
        return
      }

      do {
        formState.startLoading()
        let title = chatTitle
        let emoji = selectedEmoji
        let isPublic = isPublic
        let spaceId = spaceId
        let participants = isPublic ? [] : selectedPeople.map(\.self)

        Task.detached {
          let result = try await realtime.invokeWithHandler(
            .createChat,
            input: .createChat(.with {
              $0.title = title
              $0.spaceID = spaceId
              if let emoji { $0.emoji = emoji }
              $0.isPublic = isPublic
              $0.participants = participants
                .map {
                  userId in InputChatParticipant.with { $0.userID = Int64(userId) }
                }
            })
          )

          if case let .createChat(createChatResult) = result {
            DispatchQueue.main.async {
              formState.succeeded()
              onChatCreated(createChatResult.chat.id)
              dismiss()
            }
          }
        }
      } catch {
        formState.failed(error: error.localizedDescription)
      }
    }
  }
}

#Preview {
  CreateChatView(spaceId: 1) { _ in }
    .previewsEnvironment(.empty)
}
