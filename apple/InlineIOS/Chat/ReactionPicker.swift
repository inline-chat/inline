import SwiftUI
import UIKit

struct ReactionPickerView: View {
  let emojis: [String]
  let onEmojiSelected: (String) -> Void
  let onWillDoTapped: () -> Void
  let onShowEmojiPicker: () -> Void

  @State private var isExpanded = false

  var body: some View {
    VStack(spacing: 0) {
      // Main reaction bar
      HStack(spacing: 12) {
        ForEach(emojis, id: \.self) { emoji in
          Button(action: {
            onEmojiSelected(emoji)
          }) {
            Text(emoji)
              .font(.system(size: 24))
          }
          .buttonStyle(PlainButtonStyle())
        }

        Button(action: {
          onShowEmojiPicker()
        }) {
          Image(systemName: "plus")
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(.primary)
        }
        .buttonStyle(ReactionButtonStyle())
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(
        Capsule()
          .fill(Color(UIColor.secondarySystemBackground))
          .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 2)
      )
    }
  }
}

// MARK: - Reaction Button Style

struct ReactionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .padding(8)
      .background(
        Circle()
          .fill(
            configuration.isPressed ?
              Color(UIColor.systemGray5) :
              Color(UIColor.systemBackground)
          )
      )
      .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
      .animation(.spring(response: 0.3), value: configuration.isPressed)
  }
}

// MARK: - Emoji Grid View

struct EmojiGridView: View {
  let onEmojiSelected: (String) -> Void

  var emojis: [String] { getAllEmojis() }

  var body: some View {
    VStack {
      ScrollView {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 8) {
          ForEach(emojis, id: \.self) { emoji in
            Button(action: {
              onEmojiSelected(emoji)
            }) {
              Text(emoji)
                .font(.system(size: 24))
            }
            .buttonStyle(PlainButtonStyle())
            .padding(4)
          }
        }
        .padding()
      }
    }
  }

  func getAllEmojis() -> [String] {
    var emojis: [String] = []

    // Unicode ranges for emoji characters
    let ranges: [(start: UInt32, end: UInt32)] = [
      // Basic emoji
      (0x1_F600, 0x1_F64F), // Emoticons
      (0x1_F300, 0x1_F5FF), // Misc Symbols and Pictographs
      (0x1_F680, 0x1_F6FF), // Transport and Map
      (0x1_F700, 0x1_F77F), // Alchemical Symbols
      (0x1_F780, 0x1_F7FF), // Geometric Shapes
      (0x1_F800, 0x1_F8FF), // Supplemental Arrows-C
      (0x1_F900, 0x1_F9FF), // Supplemental Symbols and Pictographs
      (0x1_FA00, 0x1_FA6F), // Chess Symbols
      (0x1_FA70, 0x1_FAFF), // Symbols and Pictographs Extended-A
      (0x2600, 0x26FF), // Miscellaneous Symbols
      (0x2700, 0x27BF), // Dingbats
      (0x2300, 0x23FF), // Miscellaneous Technical
      (0x2B00, 0x2BFF), // Miscellaneous Symbols and Arrows
      (0x3000, 0x303F), // CJK Symbols and Punctuation
      (0x3200, 0x32FF), // Enclosed CJK Letters and Months
    ]

    // Iterate through all ranges
    for range in ranges {
      for codePoint in range.start ... range.end {
        if let scalar = UnicodeScalar(codePoint) {
          let emoji = String(scalar)
          if emoji.containsEmoji {
            emojis.append(emoji)
          }
        }
      }
    }

    return emojis
  }
}

// MARK: - UIKit Integration

class ReactionPickerHostingController: UIHostingController<ReactionPickerView> {
  private var contextMenuInteraction: UIContextMenuInteraction?

  init(
    emojis: [String],
    onEmojiSelected: @escaping (String) -> Void,
    onWillDoTapped: @escaping () -> Void,
    contextMenuInteraction: UIContextMenuInteraction?
  ) {
    self.contextMenuInteraction = contextMenuInteraction

    let rootView = ReactionPickerView(
      emojis: emojis,
      onEmojiSelected: onEmojiSelected,
      onWillDoTapped: onWillDoTapped,
      onShowEmojiPicker: {
        // Dismiss the context menu
        contextMenuInteraction?.dismissMenu()

        // After a delay, show the emoji picker sheet
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
          NotificationCenter.default.post(name: Notification.Name("ShowEmojiPickerSheet"), object: nil)
        }
      }
    )

    super.init(rootView: rootView)

    view.backgroundColor = .clear
    view.isOpaque = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
  }
}
