import InlineKit
import InlineUI
import Logger
import SwiftUI

struct CreateSpaceView: View {
  let onCreated: (Int64) -> Void

  let theme = ThemeManager.shared.selected

  @State private var photoData: Data?
  @State private var isProcessingPhoto = false
  @State private var name = ""
  @State private var emoji = ""
  @FocusState private var isFocused: Bool
  @FocusState private var showEmojiPicker: Bool
  @FormState var formState

  @Environment(\.appDatabase) var database
  @EnvironmentObject var dataManager: DataManager

  var body: some View {
    Form {
      Section {
        IOSSpacePhotoPicker(
          photoData: $photoData,
          space: Space(id: 0, name: name, date: .now),
          isBusy: formState.isLoading,
          isProcessing: $isProcessingPhoto
        )
        .frame(maxWidth: .infinity)
      }

      Section {
        HStack(spacing: 12) {
          Circle().fill(Color(theme.accent).opacity(0.1))
            .scaledFrame(width: 52, height: 52)
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
    .disabled(formState.isLoading || isProcessingPhoto)
    .safeAreaInset(edge: .bottom) {
      if let error = formState.error, !error.isEmpty {
        Text(error).font(.caption).foregroundStyle(.red).padding()
      }
    }
    .navigationTitle("Create New Space")
    .hideTabBarIfNeeded()
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
            .disabled(formState.isLoading || isProcessingPhoto)
          } else {
            Button(action: {
              submit()
            }) {
              Text(formState.isLoading ? "Creating..." : "Create")
            }
            .tint(Color(theme.accent))
            .disabled(formState.isLoading || isProcessingPhoto)
          }
        }
      }
    }
  }

  private func submit() {
    guard !formState.isLoading, !isProcessingPhoto, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    Task {
      do {
        formState.startLoading()
        let spaceName = emoji.isEmpty ? name : "\(emoji) \(name)"
        let id = try await dataManager.createSpace(name: spaceName, photoData: photoData)

        formState.succeeded()

        if let id {
          onCreated(id)
        }

      } catch {
        Log.shared.error("Failed to create space", error: error)
        formState.failed(error: error.localizedDescription)
      }
    }
  }
}

#Preview {
  CreateSpaceView(onCreated: { _ in })
}
