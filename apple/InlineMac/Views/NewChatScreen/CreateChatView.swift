import InlineKit
import InlineProtocol
import Logger
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
  @State private var showParticipantPicker = false

  @FocusState private var isTitleFocused: Bool

  // Sample emoji collection
  let emojis = ["👥", "💬", "🎯", "🛍️", "🛒", "💵", "🎧", "📚", "🍕", "📈", "⚙️", "🚧", "🏪", "🏡", "🎪", "🌴", "📁", "🤝", "🛖"]

  // Space view model
  @StateObject private var spaceViewModel: SpaceFullMembersViewModel

  public init(spaceId: Int64, onChatCreated: @escaping (Int64) -> Void) {
    self.spaceId = spaceId
    self.onChatCreated = onChatCreated
    _spaceViewModel = StateObject(wrappedValue: SpaceFullMembersViewModel(db: AppDatabase.shared, spaceId: spaceId))
  }

  public var body: some View {
    mainForm
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .navigationTitle("Create Chat")
      .sheet(isPresented: $showParticipantPicker) {
        SelectParticipantsSheet(
          spaceId: spaceId,
          selectedUserIds: $selectedPeople,
          db: db,
          isPresented: $showParticipantPicker
        )
      }
      .task {
        // Refresh members from server
        await spaceViewModel.refetchMembers()
      }
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
    Section(header: Text("New Chat In \(spaceViewModel.space?.name ?? "Space")")) {
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
      HStack {
        Text(selectedPeople.isEmpty ? "Select participants" : "\(selectedPeople.count) participant\(selectedPeople.count == 1 ? "" : "s") selected")
          .foregroundColor(selectedPeople.isEmpty ? .secondary : .primary)
        Spacer()
        Image(systemName: "chevron.right")
          .foregroundColor(.secondary)
          .font(.system(size: 12))
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .onTapGesture {
        showParticipantPicker = true
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

        let result = try await realtime.invokeWithHandler(
          .createChat,
          input: .createChat(.with {
            $0.title = title
            $0.spaceID = spaceId
            if let emoji { $0.emoji = emoji }
            $0.isPublic = isPublic
            $0.participants = participants.map { userId in InputChatParticipant.with { $0.userID = userId } }
          })
        )

        if case let .createChat(createChatResult) = result {
          formState.succeeded()
          onChatCreated(createChatResult.chat.id)
          dismiss()
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
