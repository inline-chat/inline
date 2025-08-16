import InlineKit
import InlineUI
import Logger
import SwiftUI

struct ShareView: View {
  @EnvironmentObject private var state: ShareState
  @State private var searchText: String = ""
  @Environment(\.extensionContext) private var extensionContext

  private let log = Log.scoped("ShareView")

  private var filteredChats: [SharedChat] {
    guard let chats = state.sharedData?.shareExtensionData.first?.chats else { return [] }

    let users = state.sharedData?.shareExtensionData.first?.users ?? []
    let sortedChats = sortChats(chats)

    if searchText.isEmpty {
      return sortedChats
    }

    return sortedChats.filter { chat in
      let chatName = getChatName(for: chat, users: users)
      return chatName.localizedCaseInsensitiveContains(searchText)
    }
  }

  private func sortChats(_ chats: [SharedChat]) -> [SharedChat] {
    chats.sorted { chat1, chat2 in
      // First sort by pinned status
      let pinned1 = chat1.pinned ?? false
      let pinned2 = chat2.pinned ?? false
      if pinned1 != pinned2 {
        return pinned1 && !pinned2
      }

      // Then sort by last message date
      let date1 = chat1.lastMessageDate ?? Date.distantPast
      let date2 = chat2.lastMessageDate ?? Date.distantPast
      return date1 > date2
    }
  }

  private func getChatName(for chat: SharedChat, users: [SharedUser]) -> String {
    if !chat.title.isEmpty { return chat.title }
    if let peerUserId = chat.peerUserId,
       let user = users.first(where: { $0.id == peerUserId })
    {
      return user.firstName
    }

    log.warning("Failed to find a name for chat \(chat)")
    return "Unknown"
  }

  private var navigationTitle: String {
    switch state.sharedContent {
      case let .images(images):
        "Sharing \(images.count) image\(images.count == 1 ? "" : "s")"
      case .text:
        "Sharing message"
      case .url:
        "Sharing link"
      case .file:
        "Sharing file"
      case .none:
        "Share"
    }
  }

  var body: some View {
    NavigationView {
      Group {
        if state.isSent {
          VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 48))
              .foregroundStyle(.green)
              .symbolEffect(.bounce, value: state.isSent)
              .symbolRenderingMode(.hierarchical)
            Text("Sent")
              .font(.headline)
              .foregroundStyle(.primary)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .transition(.asymmetric(
            insertion: .scale.combined(with: .opacity),
            removal: .opacity
          ))
        } else if state.isSending {
          VStack(spacing: 16) {
            ProgressView()
              .scaleEffect(1.2)
            Text("Sending...")
              .font(.headline)
              .foregroundStyle(.primary)
            if state.uploadProgress > 0 {
              ProgressView(value: state.uploadProgress)
                .frame(maxWidth: 200)
                .transition(.opacity.combined(with: .scale))
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .transition(.asymmetric(
            insertion: .scale.combined(with: .opacity),
            removal: .opacity
          ))
        } else {
          VStack(spacing: 0) {
            // Search bar
            HStack {
              Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
              TextField("Search chats", text: $searchText)
            }
            .padding()
            .background(Color(.systemGray6))

            // Chat list
            List(filteredChats, id: \.id) { chat in
              ChatRowView(
                chat: chat,
                users: state.sharedData?.shareExtensionData.first?.users ?? [],
                onTap: {
                  // Send immediately on selection
                  state.sendMessage(caption: "", selectedChat: chat) {
                    extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
                  }
                }
              )
            }
            .listStyle(.plain)
          }
          .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
          ))
        }
      }
      .animation(.easeInOut(duration: 0.3), value: state.isSent)
      .animation(.easeInOut(duration: 0.3), value: state.isSending)
    }
    .navigationTitle(navigationTitle)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .navigationBarLeading) {
        Button("Close") {
          extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
      }
    }
    .onAppear {
      state.loadSharedData()
    }
    .alert(
      state.errorState?.title ?? "Error",
      isPresented: Binding(
        get: { state.errorState != nil },
        set: { if !$0 { state.errorState = nil } }
      )
    ) {
      Button("OK", role: .cancel) {
        state.errorState = nil
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
      }
    } message: {
      if let message = state.errorState?.message {
        Text(message)
      }
    }
  }
}

// MARK: - Chat Row View

struct ChatRowView: View {
  let chat: SharedChat
  let users: [SharedUser]
  let onTap: () -> Void

  private func getChatName() -> String {
    if !chat.title.isEmpty { return chat.title }
    if let peerUserId = chat.peerUserId,
       let user = users.first(where: { $0.id == peerUserId })
    {
      return user.firstName
    }
    return "Unknown"
  }

  var body: some View {
    Button(action: onTap) {
      HStack {
        InitialsCircle(
          name: getChatName(),
          size: 40,
          emoji: chat.emoji
        )

        VStack(alignment: .leading, spacing: 2) {
          HStack {
            Text(getChatName())
              .font(.body)
              .foregroundStyle(.primary)

            if chat.pinned == true {
              Image(systemName: "pin.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }

          if let spaceName = chat.spaceName, !spaceName.isEmpty {
            Text(spaceName)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Spacer()
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
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
