import SwiftUI

struct EmojiPickerView: View {
  @Binding var selectedEmoji: String?
  @Binding var isPresented: Bool
  
  let emojis = [
    "😀", "😃", "😄", "😁", "😆", "😅", "😂", "🤣", "😊", "😇",
    "🙂", "🙃", "😉", "😌", "😍", "🥰", "😘", "😗", "😙", "😚",
    "😋", "😛", "😝", "😜", "🤪", "🤨", "🧐", "🤓", "😎", "🤩",
    "🥳", "😏", "😒", "😞", "😔", "😟", "😕", "🙁", "☹️", "😣",
    "😖", "😫", "😩", "🥺", "😢", "😭", "😤", "😠", "😡", "🤬",
    "🤯", "😳", "🥵", "🥶", "😱", "😨", "😰", "😥", "😓", "🤗",
    "🤔", "🤭", "🤫", "🤥", "😶", "😐", "😑", "😬", "🙄", "😯",
    "😦", "😧", "😮", "😲", "🥱", "😴", "🤤", "😪", "😵", "🤐",
    "🥴", "🤢", "🤮", "🤧", "😷", "🤒", "🤕", "🤑", "🤠", "😈",
    "👿", "👹", "👺", "🤡", "💩", "👻", "💀", "☠️", "👽", "👾"
  ]
  
  let columns = Array(repeating: GridItem(.flexible()), count: 8)
  
  var body: some View {
    VStack(spacing: 16) {
      HStack {
        Button("Cancel") {
          isPresented = false
        }
        Spacer()
        Button("Clear") {
          selectedEmoji = nil
          isPresented = false
        }
      }
      .padding(.horizontal)
      
      ScrollView {
        LazyVGrid(columns: columns, spacing: 12) {
          ForEach(emojis, id: \.self) { emoji in
            Button(emoji) {
              selectedEmoji = emoji
              isPresented = false
            }
            .font(.title2)
            .frame(width: 40, height: 40)
            .background(
              selectedEmoji == emoji ? Color.blue.opacity(0.2) : Color.clear
            )
            .cornerRadius(8)
          }
        }
        .padding(.horizontal)
      }
    }
    .frame(width: 350, height: 400)
    .padding(.vertical)
  }
}

#Preview {
  EmojiPickerView(selectedEmoji: .constant(nil), isPresented: .constant(true))
}