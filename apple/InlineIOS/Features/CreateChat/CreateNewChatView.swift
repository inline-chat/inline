import InlineKit
import SwiftUI

struct CreateNewChatView: View {
  @EnvironmentObject var compactSpaceList: CompactSpaceList

  let theme = ThemeManager.shared.selected
  var spaceId: Int64?

  @FocusState private var isFocused: Bool
  @FocusState private var showEmojiPicker: Bool

  @Binding private var text: String
  @Binding private var emoji: String
  @Binding private var selectedRoute: Route
  @Binding private var selectedSpaceId: Int64?
  @Binding private var selectedSpaceName: String?

  @State private var showProfileSheet = false

  init(
    text: Binding<String>,
    emoji: Binding<String>,
    selectedRoute: Binding<Route>,
    spaceId: Int64?,
    selectedSpaceId: Binding<Int64?>,
    selectedSpaceName: Binding<String?>
  ) {
    _text = text
    _emoji = emoji
    _selectedRoute = selectedRoute
    self.spaceId = spaceId
    _selectedSpaceId = selectedSpaceId
    _selectedSpaceName = selectedSpaceName
  }

  var body: some View {
    Group {
      Section {
        HStack(spacing: 12) {
          Circle().fill(Color(theme.accent).opacity(0.1))
            .frame(width: 52, height: 52)
            .overlay {
              ZStack {
                TextField("", text: $emoji)
                  .focused($showEmojiPicker)
                  .keyboardType(.emoji ?? .default)
                  .textFieldStyle(.plain)
                  .font(.title)
                  .padding(.leading, 10)
                  .onChange(of: emoji) { _, newValue in
                    if newValue.count >= 1 {
                      let firstEmoji = String(newValue.first!)
                      if emoji != firstEmoji {
                        emoji = firstEmoji
                      }
                      showEmojiPicker = false
                      if text.isEmpty {
                        isFocused = true
                      }
                    }
                  }

                Image(systemName: "face.smiling")
                  .font(.title)
                  .foregroundStyle(Color(theme.accent))
                  .opacity(showEmojiPicker || !emoji.isEmpty ? 0 : 1)
              }
            }
            .onTapGesture {
              showEmojiPicker = true
            }

          TextField("Chat title", text: $text)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .onSubmit {
              isFocused = false
            }
            .onAppear {
              isFocused = true
            }
        }
      }
      Section {
        if spaceId == nil {
          Picker("Select a space", selection: $selectedSpaceId) {
            Text("Select a space").tag(nil as Int64?)
            ForEach(compactSpaceList.spaces) { space in
              Text(space.nameWithoutEmoji).tag(space.id as Int64?)
            }
          }
          .onAppear {
            if selectedSpaceId == nil, !compactSpaceList.spaces.isEmpty {
              selectedSpaceId = compactSpaceList.spaces.first?.id
              selectedSpaceName = compactSpaceList.spaces.first?.nameWithoutEmoji
            }
          }
          .pickerStyle(.menu)
        }
      }
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          if #available(iOS 26.0, *) {
            Button(action: {
              isFocused = false
              showEmojiPicker = false
              selectedRoute = .visibility
            }) {
              Image(systemName: "arrow.right")
            }
            .disabled(spaceId == nil && selectedSpaceId == nil || text.isEmpty)
            .buttonStyle(.glassProminent)

          } else {
            Button(action: {
              isFocused = false
              showEmojiPicker = false

              selectedRoute = .visibility
            }) {
              Text("Next")
            }
            .disabled(spaceId == nil && selectedSpaceId == nil || text.isEmpty)
            .tint(Color(theme.accent))
          }
        }
      }
    }
  }
}

extension UIKeyboardType {
  static let emoji = UIKeyboardType(rawValue: 124)
}
