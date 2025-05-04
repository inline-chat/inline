import InlineKit
import InlineProtocol
import SwiftUI

struct NewChatSwiftUI: View {
  @Environment(\.appDatabase) var db
  @EnvironmentObject var nav: Nav
  @FormState var formState
  
  private let spaceId: Int64

  @State private var chatTitle = ""
  @State private var selectedEmoji: String? = nil
  @State private var isPublic = true
  @State private var showEmojiPicker = false
  @State private var selectedPeople: Set<Int64> = []

  // Sample emoji collection
  let emojis = ["👥", "💬", "🎯", "🛍️", "🛒", "💵", "🎧", "📚", "🍕", "📈", "⚙️", "🚧", "🏪", "🏡", "🎪", "🌴", "📁", "🤝", "🛖"]

  // Space view model
  @StateObject private var spaceViewModel: FullSpaceViewModel

  init(spaceId: Int64) {
    self.spaceId = spaceId
    _spaceViewModel = StateObject(wrappedValue: FullSpaceViewModel(db: AppDatabase.shared, spaceId: spaceId))
  }

  var body: some View {
    mainForm
      .formStyle(.grouped)
      .padding()
      .scrollContentBackground(.hidden)
      .frame(width: 500, height: 600)
      .navigationTitle("Create Group Chat")
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
    .font(.system(size: 14))
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
            .font(.system(size: 18))
            .frame(width: 28, height: 28)
        } else {
          Image(systemName: "message.fill")
            .font(.system(size: 14))
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color.gray.opacity(0.2)))
        }
      }
      .buttonStyle(PlainButtonStyle())
      .popover(isPresented: $showEmojiPicker) {
        emojiPickerView
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
          Text("Create Group Chat")
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

        // Create the transaction
        let transaction = TransactionCreateChat(
          title: chatTitle,
          emoji: selectedEmoji,
          isPublic: isPublic,
          spaceId: spaceId,
          participants: isPublic ? [] : selectedPeople.map { $0 },
        )

        // Execute the transaction
        Transactions.shared.mutate(transaction: .createChat(transaction))

        formState.succeeded()

        // Navigate back
//        DispatchQueue.main.async {
//          nav.pop()
//        }
      } catch {
        formState.failed(error: error.localizedDescription)
      }
    }
  }
}

#Preview {
  NewChatSwiftUI(spaceId: 1)
    .previewsEnvironment(.empty)
}
