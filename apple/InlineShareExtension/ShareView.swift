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
    guard let chats = state.sharedData?.shareExtensionData.chats else { return [] }

    let users = state.sharedData?.shareExtensionData.users ?? []
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
      let displayName = user.displayName ?? ""
      if !displayName.isEmpty {
        return displayName
      } else {
        let firstName = user.firstName
        let lastName = user.lastName
        let fullName = [firstName, lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return fullName.isEmpty ? "Unknown User" : fullName
      }
    }

    log.warning("Failed to find a name for chat \(chat)")
    return "Unknown"
  }

  private var navigationTitle: String {
    guard let content = state.sharedContent else { return "Share" }
    let photoCount = content.photoCount
    let videoCount = content.videoCount
    let documentCount = content.documentCount

    if photoCount > 0 && videoCount == 0 && documentCount == 0 && !content.hasText && !content.hasUrls {
      return "Sharing \(photoCount) photo\(photoCount == 1 ? "" : "s")"
    }
    if videoCount > 0 && photoCount == 0 && documentCount == 0 && !content.hasText && !content.hasUrls {
      return "Sharing \(videoCount) video\(videoCount == 1 ? "" : "s")"
    }
    if documentCount > 0 && photoCount == 0 && videoCount == 0 && !content.hasText && !content.hasUrls {
      return "Sharing \(documentCount) file\(documentCount == 1 ? "" : "s")"
    }
    if content.hasUrls && !content.hasMedia && !content.hasText {
      return "Sharing \(content.urls.count) link\(content.urls.count == 1 ? "" : "s")"
    }
    if content.hasText && !content.hasMedia && !content.hasUrls {
      return "Sharing message"
    }
    let totalCount = content.totalItemCount
    return totalCount > 1 ? "Sharing \(totalCount) items" : "Share"
  }

  var body: some View {
    NavigationView {
      VStack(spacing: 0) {
        // Clear heading for the sheet
        headerView
        
        contentView
      }
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button("Close") {
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
          }
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
      Button("Close", role: .cancel) {
        state.errorState = nil
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
      }
    } message: {
      VStack(alignment: .leading, spacing: 4) {
        if let message = state.errorState?.message {
          Text(message)
        }
        if let suggestion = state.errorState?.suggestion {
          Text(suggestion)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }
  
  @ViewBuilder
  private var headerView: some View {
    VStack(spacing: 8) {
      Text(navigationTitle)
        .font(.title2)
        .fontWeight(.semibold)
        .foregroundStyle(.primary)
      
      if let content = state.sharedContent, content.totalItemCount > 1 {
        Text("\(content.totalItemCount) items selected")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 16)
    .padding(.horizontal, 20)
    .background(Color(.systemBackground))
  }
  
  @ViewBuilder
  private var contentView: some View {
    Group {
      if state.isSent {
        successView
      } else if state.isSending {
        sendingView
      } else if state.isLoadingContent {
        loadingView
      } else if state.sharedContent == nil {
        noContentView
      } else {
        chatSelectionView
      }
    }
    .animation(.easeInOut(duration: 0.3), value: state.isSent)
    .animation(.easeInOut(duration: 0.3), value: state.isSending)
  }
  
  @ViewBuilder
  private var successView: some View {
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
  }
  
  @ViewBuilder
  private var sendingView: some View {
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
  }

  @ViewBuilder
  private var loadingView: some View {
    VStack(spacing: 16) {
      ProgressView()
        .scaleEffect(1.2)
      Text("Preparing your share...")
        .font(.headline)
        .foregroundStyle(.primary)
      Text("This can take a moment for large files.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .transition(.opacity)
  }

  @ViewBuilder
  private var noContentView: some View {
    VStack(spacing: 16) {
      Image(systemName: "tray")
        .font(.system(size: 40))
        .foregroundStyle(.secondary)
      Text("Nothing to share")
        .font(.headline)
        .foregroundStyle(.secondary)
      Text("Go back and select something to share, then try again.")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .transition(.opacity)
  }
  
  @ViewBuilder
  private var chatSelectionView: some View {
    VStack(spacing: 0) {
      // Search bar with idiomatic styling
      searchBar
      
      // Chat list
      if filteredChats.isEmpty {
        emptyStateView
      } else {
        chatListView
      }
    }
    .transition(.asymmetric(
      insertion: .move(edge: .bottom).combined(with: .opacity),
      removal: .opacity
    ))
  }
  
  @ViewBuilder
  private var searchBar: some View {
    HStack {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
        .font(.system(size: 16))
      
      TextField("Search chats", text: $searchText)
        .textFieldStyle(.plain)
        .font(.body)
        .accessibilityLabel("Search chats")
        .accessibilityHint("Enter text to filter your chat list")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(Color(.systemGray6))
    )
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
  }
  
  @ViewBuilder
  private var emptyStateView: some View {
    VStack(spacing: 16) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 40))
        .foregroundStyle(.secondary)
      Text("No chats found")
        .font(.headline)
        .foregroundStyle(.secondary)
      Text("Try a different search term")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  
  @ViewBuilder
  private var chatListView: some View {
    List(filteredChats, id: \.id) { chat in
      ChatRowView(
        chat: chat,
        users: state.sharedData?.shareExtensionData.users ?? [],
        onTap: {
          state.sendMessage(caption: "", selectedChat: chat) {
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
          }
        }
      )
    }
    .listStyle(.plain)
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
      let displayName = user.displayName ?? ""
      if !displayName.isEmpty {
        return displayName
      } else {
        let firstName = user.firstName
        let lastName = user.lastName
        let fullName = [firstName, lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return fullName.isEmpty ? "Unknown User" : fullName
      }
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
                .accessibilityLabel("Pinned chat")
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
    .buttonStyle(.plain)
    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    .accessibilityLabel("Share with \(getChatName())")
    .accessibilityHint("Tap to send content to this chat")
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
