import MCEmojiPicker
import SwiftUI

struct ReactionPickerView: View {
  let emojis: [String]
  let onEmojiSelected: (String) -> Void
  let onWillDoTapped: () -> Void

  @State private var isEmojiPickerPresented: Bool = false
  @State private var selectedEmoji: String = ""

  var body: some View {
    HStack(spacing: 10) {
      Button(action: {
        isEmojiPickerPresented = true
      }) {
        Image(systemName: "plus")
          .font(.title2)
          .foregroundColor(.gray)
      }
      .buttonStyle(PlainButtonStyle())
      .fixedSize()
      .emojiPicker(
        isPresented: $isEmojiPickerPresented,
        selectedEmoji: $selectedEmoji
      )
      ForEach(emojis, id: \.self) { emoji in
        Button(action: {
          onEmojiSelected(emoji)
        }) {
          Text(emoji)
            .font(.title2)
        }
        .buttonStyle(PlainButtonStyle())
        .fixedSize()
      }

//      Button(action: {
//        onWillDoTapped()
//      }) {
//        Text("Will Do")
//          .font(.system(size: 15, weight: .semibold))
//          .foregroundColor(.white)
//          .padding(.horizontal, 12)
//          .padding(.vertical, 6)
//          .background(
//            Capsule()
//              .fill(
//                LinearGradient(
//                  gradient: Gradient(colors: [Color.purple.opacity(0.6), Color.purple]),
//                  startPoint: .leading,
//                  endPoint: .trailing
//                )
//              )
//          )
//      }
//      .buttonStyle(PlainButtonStyle())
//      .fixedSize()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color(UIColor.systemBackground))
    .cornerRadius(25)
    .frame(maxWidth: .infinity)
    .onChange(of: selectedEmoji) { _, newValue in
      if !newValue.isEmpty {
        onEmojiSelected(newValue)
        selectedEmoji = ""
      }
    }
  }
}

// MARK: - UIKit Integration

class ReactionPickerHostingController: UIHostingController<ReactionPickerView> {
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
  }
}
