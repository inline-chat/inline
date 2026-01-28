import InlineKit
import InlineUI
import SwiftUI

struct ChatInfo: View {
  @EnvironmentStateObject var fullChat: FullChatViewModel
  @EnvironmentStateObject private var documentsState: ChatInfoDocumentsState

  var peerId: Peer
  @State private var selectedTab: ChatInfoTab = .files

  public init(peerId: Peer) {
    self.peerId = peerId
    _fullChat = EnvironmentStateObject { env in
      FullChatViewModel(db: env.appDatabase, peer: peerId)
    }
    _documentsState = EnvironmentStateObject { env in
      ChatInfoDocumentsState(db: env.appDatabase, peer: peerId)
    }
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 24) {
        header

        Picker("Tabs", selection: $selectedTab) {
          ForEach(availableTabs, id: \.self) { tab in
            Text(tab.title).tag(tab)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16)

        tabContent
      }
      .padding(.top, 16)
      .padding(.bottom, 24)
    }
    .frame(maxWidth: .infinity, alignment: .top)
    .onAppear {
      updateDocumentsChatId()
      ensureSelectedTab()
    }
    .onChange(of: chatId) { _ in
      updateDocumentsChatId()
    }
    .onChange(of: availableTabsKey) { _ in
      ensureSelectedTab()
    }
  }

  @ViewBuilder
  var icon: some View {
    if let userInfo = fullChat.chatItem?.userInfo {
      ChatIcon(peer: .user(userInfo), size: 100)
    } else if let chat = fullChat.chatItem?.chat {
      ChatIcon(peer: .chat(chat), size: 100)
    } else {
      EmptyView()
    }
  }

  @ViewBuilder
  private var header: some View {
    VStack(spacing: 8) {
      icon
        .padding(.top, 8)

      Text(chatTitle)
        .font(.title2)
        .fontWeight(.semibold)
    }
    .frame(maxWidth: .infinity)
  }

  private var chatTitle: String {
    fullChat.chatItem?.title ?? "Chat"
  }

  private var chatId: Int64? {
    fullChat.chat?.id ?? fullChat.chatItem?.dialog.chatId
  }

  private var isPrivateThread: Bool {
    guard case .thread = peerId else { return false }
    guard let isPublic = fullChat.chat?.isPublic else { return false }
    return isPublic == false
  }

  private var availableTabs: [ChatInfoTab] {
    var tabs: [ChatInfoTab] = [.files, .media, .links]
    if isPrivateThread {
      tabs.append(.participants)
    }
    return tabs
  }

  private var availableTabsKey: String {
    availableTabs.map(\.title).joined(separator: "|")
  }

  private func ensureSelectedTab() {
    guard availableTabs.contains(selectedTab) else {
      selectedTab = availableTabs.first ?? .files
      return
    }
  }

  private func updateDocumentsChatId() {
    guard let chatId, chatId > 0 else { return }
    documentsState.updateChatId(chatId)
  }

  @ViewBuilder
  private var tabContent: some View {
    switch selectedTab {
      case .files:
        filesTab
      case .media:
        comingSoonView(title: "Media", message: "Media browsing is coming soon.")
      case .links:
        comingSoonView(title: "Links", message: "Links browsing is coming soon.")
      case .participants:
        comingSoonView(title: "Participants", message: "Participants management is coming soon.")
    }
  }

  @ViewBuilder
  private var filesTab: some View {
    if let documentsViewModel = documentsState.documentsViewModel {
      ChatInfoFilesList(documentsViewModel: documentsViewModel)
    } else {
      HStack {
        Spacer()
        ProgressView()
          .controlSize(.small)
        Spacer()
      }
      .padding(.vertical, 32)
    }
  }

  private func comingSoonView(title: String, message: String) -> some View {
    VStack(spacing: 8) {
      Text(title)
        .font(.headline)
      Text(message)
        .foregroundStyle(.secondary)
        .font(.subheadline)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 40)
  }
}

private enum ChatInfoTab: String, CaseIterable, Hashable {
  case files
  case media
  case links
  case participants

  var title: String {
    rawValue.capitalized
  }
}

@MainActor
private final class ChatInfoDocumentsState: ObservableObject {
  @Published private(set) var documentsViewModel: ChatDocumentsViewModel?

  private let db: AppDatabase
  private let peer: Peer
  private var currentChatId: Int64 = 0

  init(db: AppDatabase, peer: Peer) {
    self.db = db
    self.peer = peer
  }

  func updateChatId(_ chatId: Int64) {
    guard chatId > 0 else { return }
    guard chatId != currentChatId else { return }
    currentChatId = chatId
    documentsViewModel = ChatDocumentsViewModel(db: db, chatId: chatId, peer: peer)
  }
}

private struct ChatInfoFilesList: View {
  @ObservedObject var documentsViewModel: ChatDocumentsViewModel

  var body: some View {
    Group {
      if documentsViewModel.documentMessages.isEmpty {
        Text("No files found in this chat.")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.vertical, 32)
      } else {
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(documentsViewModel.groupedDocumentMessages, id: \.date) { group in
            VStack(alignment: .leading, spacing: 6) {
              Text(formatDate(group.date))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 6)

              ForEach(group.messages, id: \.id) { documentMessage in
                ChatInfoDocumentRow(documentMessage: documentMessage)
                  .padding(.horizontal, 16)
                  .padding(.vertical, 4)
                  .onAppear {
                    Task {
                      await documentsViewModel.loadMoreIfNeeded(currentMessageId: documentMessage.message.id)
                    }
                  }
              }
            }
            Divider()
              .padding(.leading, 16)
          }
        }
      }
    }
    .task {
      await documentsViewModel.loadInitial()
    }
  }

  private func formatDate(_ date: Date) -> String {
    let calendar = Calendar.current
    let now = Date()

    if calendar.isDateInToday(date) {
      return "Today"
    } else if calendar.isDateInYesterday(date) {
      return "Yesterday"
    } else if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
      let formatter = DateFormatter()
      formatter.dateFormat = "EEEE"
      return formatter.string(from: date)
    } else {
      let formatter = DateFormatter()
      formatter.dateFormat = "MMMM d, yyyy"
      return formatter.string(from: date)
    }
  }
}

private struct ChatInfoDocumentRow: NSViewRepresentable {
  let documentMessage: DocumentMessage

  func makeNSView(context: Context) -> DocumentView {
    let view = DocumentView(
      documentInfo: documentMessage.document,
      fullMessage: makeFullMessage(from: documentMessage)
    )
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }

  func updateNSView(_ nsView: DocumentView, context: Context) {
    nsView.update(with: documentMessage.document)
  }

  private func makeFullMessage(from documentMessage: DocumentMessage) -> FullMessage {
    FullMessage(
      senderInfo: nil,
      message: documentMessage.message,
      reactions: [],
      repliedToMessage: nil,
      attachments: []
    )
  }
}

// TODO: Previews
