import InlineKit
import InlineUI
import Logger
import SwiftUI

struct CreateSpaceView: View {
  let theme = ThemeManager.shared.selected

  @State private var name = ""
  @State private var emoji = ""
  @FocusState private var isFocused: Bool
  @FocusState private var showEmojiPicker: Bool
  @FormState var formState

  @Environment(\.appDatabase) var database
  @Environment(Router.self) private var router
  @EnvironmentObject var dataManager: DataManager

  var body: some View {
    Form {
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
                      if name.isEmpty {
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

          TextField("Space name", text: $name)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .onSubmit {
              if !name.isEmpty {
                submit()
              }
            }
            .onAppear {
              isFocused = true
            }
        }
      }
    }
    .navigationTitle("Create New Space")
    .toolbar(.hidden, for: .tabBar)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if !name.isEmpty {
          if #available(iOS 26.0, *) {
            Button(action: {
              submit()
            }) {
              if formState.isLoading {
                ProgressView()
                  .scaleEffect(0.8)
              } else {
                Image(systemName: "checkmark")
              }
            }
            .buttonStyle(.glassProminent)
            .disabled(formState.isLoading)
          } else {
            Button(action: {
              submit()
            }) {
              Text(formState.isLoading ? "Creating..." : "Create")
            }
            .tint(Color(theme.accent))
            .disabled(formState.isLoading)
          }
        }
      }
    }
  }

  private func submit() {
    Task {
      do {
        formState.startLoading()
        let spaceName = emoji.isEmpty ? name : "\(emoji) \(name)"
        let id = try await dataManager.createSpace(name: spaceName)

        formState.succeeded()

        if let id {
          router.popToRoot()
          router.selectedTab = .spaces
          router.push(.space(id: id))
        }

      } catch {
        Log.shared.error("Failed to create space", error: error)
        formState.failed(error: error.localizedDescription)
      }
    }
  }
}

#Preview {
  CreateSpaceView()
}
