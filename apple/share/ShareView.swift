import InlineKit
import InlineUI
import Logger
import SwiftUI

struct ShareView: View {
  @EnvironmentObject private var state: ShareState
  @State private var caption: String = ""
  @State private var selectedChat: SharedChat?
  @State private var isLoading: Bool = false
  @Environment(\.extensionContext) private var extensionContext

  private let log = Log.scoped("ShareView")

  private var selectedChatName: String? {
    guard let selectedChat,
          let users = state.sharedData?.shareExtensionData.first?.users else { return nil }

    if !selectedChat.title.isEmpty { return selectedChat.title }
    if let peerUserId = selectedChat.peerUserId,
       let user = users.first(where: { $0.id == peerUserId })
    {
      return user.firstName
    }
    return nil
  }

  var body: some View {
    VStack(spacing: 0) {
      // Header
      VStack(spacing: 2) {
        Text("Share with")
          .font(.title2)
          .fontWeight(.semibold)

        if let name = selectedChatName {
          Text(name)
            .foregroundColor(.secondary)
            .font(.subheadline)
        } else {
          Text("Select chats")
            .foregroundColor(.secondary)
            .font(.subheadline)
        }
      }
      .padding(.vertical, 16)

      // Chat Grid
      ScrollView {
        LazyVGrid(columns: [
          GridItem(.flexible(minimum: 70), spacing: 16),
          GridItem(.flexible(minimum: 70), spacing: 16),
          GridItem(.flexible(minimum: 70), spacing: 16),
          GridItem(.flexible(minimum: 70), spacing: 16),
        ], spacing: 16) {
          if let chats = state.sharedData?.shareExtensionData.first?.chats,
             let users = state.sharedData?.shareExtensionData.first?.users
          {
            ForEach(chats, id: \.id) { chat in
              ChatAvatarButton(
                chat: chat,
                users: users,
                selectedChat: $selectedChat
              )
            }
          }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
      }

      Spacer()

      // Caption field
      TextField("Add a comment...", text: $caption)
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(16)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)

      // Send button
      Button {
        if let selectedChat {
          isLoading = true
          state.sendMessage(caption: caption, selectedChat: selectedChat) {
            isLoading = false
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
          }
        }
      } label: {
        HStack {
          Text(isLoading ? "Sending..." : "Send")
            .fontWeight(.medium)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(selectedChat != nil ? Color.blue : isLoading ? Color.secondary : Color.blue.opacity(0.5))
        .foregroundColor(.white)
        .cornerRadius(16)
        .padding(.horizontal, 16)
      }
      .disabled(selectedChat == nil || isLoading)

      // Cancel button
      Button("Cancel") {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
      }
      .padding(.vertical, 16)
      .frame(maxWidth: .infinity)
      .foregroundColor(.blue)
      .disabled(isLoading)
    }
    .cornerRadius(16)
    .padding(.horizontal, 12)
    .onAppear {
      state.loadSharedData()
    }
  }
}

struct ChatAvatarButton: View {
  let chat: SharedChat
  let users: [SharedUser]
  @Binding var selectedChat: SharedChat?

  private func chatTitle() -> String {
    if !chat.title.isEmpty { return chat.title }
    if let peerUserId = chat.peerUserId,
       let user = users.first(where: { $0.id == peerUserId })
    {
      return user.firstName
    }
    return "Unknown"
  }

  private func playHaptic() {
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.impactOccurred()
  }

  var body: some View {
    Button {
      if selectedChat?.id == chat.id {
        selectedChat = nil
        playHaptic()
      } else {
        selectedChat = chat
        playHaptic()
      }
    } label: {
      VStack(spacing: 6) {
        InitialsCircle(name: chatTitle(), size: 72)
        Text(chatTitle())
          .font(.caption)
          .foregroundColor(
            chat.id == selectedChat?.id
              ? .blue
              :
              .primary
          )
          .lineLimit(1)
          .multilineTextAlignment(.center)
      }
      .overlay(alignment: .topTrailing) {
        if chat.id == selectedChat?.id {
          ZStack {
            Circle()
              .fill(Color.accentColor)
              .frame(width: 20, height: 20)
            Image(systemName: "checkmark")
              .font(.system(size: 12, weight: .bold))
              .foregroundStyle(.white)
          }
          .offset(x: 0, y: -4)
        }
      }
    }
  }
}

// MARK: - Environment Values

private struct ExtensionContextKey: EnvironmentKey {
  static let defaultValue: NSExtensionContext? = nil
}

extension EnvironmentValues {
  var extensionContext: NSExtensionContext? {
    get { self[ExtensionContextKey.self] }
    set { self[ExtensionContextKey.self] = newValue }
  }
}
