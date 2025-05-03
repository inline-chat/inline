import InlineKit
import SwiftUI

struct NewChatSwiftUI: View {
  @Environment(\.appDatabase) var db
  @EnvironmentObject var nav: Nav
  @FormState var formState

  @State private var chatTitle = ""
  @State private var selectedEmoji: String? = nil
  @State private var isPublic = true
  @State private var showEmojiPicker = false
  @State private var selectedPeople: Set<String> = []

  // Sample emoji collection
  let emojis = ["👥", "💬", "🎯", "🛍️", "🛒", "💵", "🎧", "📚", "🍕", "📈", "⚙️", "🚧", "🏪", "🏡", "🎪", "🌴", "📁", "🤝", "🛖"]

  // Sample people
  let people = [
    "Alex Kim",
    "Jamie Smith",
    "Taylor Johnson",
    "Morgan Lee",
    "Casey White",
    "Jordan Brown",
    "Riley Davis",
    "Quinn Miller",
  ]

  var body: some View {
    Form {
      Section(header: Text("New Chat")) {
        TextField(
          "Title",
          text: $chatTitle,
          prompt: Text("Enter chat title")
        )
        .textFieldStyle(.automatic)
        .font(.system(size: 14))

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
        }

        Picker("Visibility", selection: $isPublic) {
          Text("Public").tag(true)
          Text("Private").tag(false)
        }
        .pickerStyle(SegmentedPickerStyle())
      }

      if !isPublic {
        Section(header: Text("Invite People")) {
          List {
            ForEach(people, id: \.self) { person in
              HStack {
                Text(person)
                Spacer()
                if selectedPeople.contains(person) {
                  Image(systemName: "checkmark")
                    .foregroundColor(.blue)
                }
              }
              .contentShape(Rectangle())
              .onTapGesture {
                if selectedPeople.contains(person) {
                  selectedPeople.remove(person)
                } else {
                  selectedPeople.insert(person)
                }
              }
            }
          }
        }
      }

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
    .formStyle(.grouped)
    .padding()
    .frame(width: 500, height: 600)
    .navigationTitle("Create Group Chat")
  }

  // MARK: Methods

  private func submit() {
//    Task {
//      if spaceName.isEmpty {
//        return
//      }
//
//      do {
//        formState.startLoading()
//        let result = try await ApiClient.shared.createSpace(name: spaceName)
//        try await db.dbWriter.write { db in
//          try Space(from: result.space).save(db)
//          try Member(from: result.member).save(db)
//          try result.chats.forEach { chat in
//            try Chat(from: chat).save(db)
//          }
//          // ... save more stuff
//        }
//        formState.succeeded()
//
//        DispatchQueue.main.async {
//          // Navigate to the new space
//          nav.openSpace(result.space.id)
//        }
//      } catch {
//        formState.failed(error: error.localizedDescription)
//      }
//    }
  }
}

#Preview {
  NewChatSwiftUI()
    .previewsEnvironment(.empty)
}
