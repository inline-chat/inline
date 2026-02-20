import GRDB
import InlineKit
import InlineUI
import Logger
import SwiftUI

struct ChatInfo: View {
  @Environment(\.dependencies) private var dependencies
  @Environment(\.realtimeV2) private var realtimeV2
  @EnvironmentStateObject var fullChat: FullChatViewModel
  @EnvironmentStateObject private var documentsState: ChatInfoDocumentsState
  @StateObject private var appSettings = AppSettings.shared

  let peerId: Peer
  @State private var selectedTab: ChatInfoTab = .files
  @State private var isOwnerOrAdmin = false
  @State private var isCreator = false
  @State private var showVisibilityPicker = false
  @State private var showTranslationOptions = false
  @State private var isTranslationEnabled: Bool
  @State private var selectedParticipantIds: Set<Int64> = []

  private var chatTitle: String {
    if let userInfo = fullChat.chatItem?.userInfo {
      userInfo.user.fullName
    } else if let chat = fullChat.chatItem?.chat {
      chat.humanReadableTitle ?? "Chat"
    } else {
      "Chat"
    }
  }

  private var chatId: Int64? {
    fullChat.chat?.id ?? fullChat.chatItem?.dialog.chatId
  }

  private var chatTypeLabel: String {
    if peerId.isThread {
      return "Thread"
    }
    if let chatType = fullChat.chat?.type {
      switch chatType {
        case .thread:
          return "Thread"
        case .privateChat:
          return "Private"
      }
    }
    if fullChat.peerUser != nil {
      return "Private"
    }
    return "Chat"
  }

  private var notificationSelection: DialogNotificationSettingSelection {
    fullChat.chatItem?.dialog.notificationSelection ?? .global
  }

  private var visibilityLabel: String {
    if fullChat.chat?.isPublic == true {
      return "Public"
    }
    if fullChat.chat?.isPublic == false {
      return "Private"
    }
    return "Unknown"
  }

  private var shouldShowVisibilityRow: Bool {
    peerId.isThread
  }

  private var canToggleVisibility: Bool {
    guard peerId.isThread,
          let chat = fullChat.chat,
          chat.spaceId != nil,
          (isOwnerOrAdmin || isCreator)
    else {
      return false
    }
    return true
  }

  private var visibilityBinding: Binding<Bool> {
    Binding(
      get: { fullChat.chat?.isPublic ?? false },
      set: { newValue in
        handleVisibilityToggle(newValue)
      }
    )
  }

  private var translationBinding: Binding<Bool> {
    Binding(
      get: { isTranslationEnabled },
      set: { newValue in
        guard newValue != isTranslationEnabled else { return }
        isTranslationEnabled = newValue
        TranslationState.shared.setTranslationEnabled(newValue, for: peerId)
      }
    )
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

  private var permissionsTaskKey: String {
    "\(peerId.toString())-\(fullChat.chat?.spaceId ?? 0)-\(dependencies?.auth.currentUserId ?? 0)"
  }

  public init(peerId: Peer) {
    self.peerId = peerId
    _isTranslationEnabled = State(initialValue: TranslationState.shared.isTranslationEnabled(for: peerId))
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
        infoForm

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
      syncTranslationState()
    }
    .task(id: permissionsTaskKey) {
      await loadVisibilityPermissions()
    }
    .onChange(of: chatId) { _ in
      updateDocumentsChatId()
    }
    .onChange(of: availableTabsKey) { _ in
      ensureSelectedTab()
    }
    .onReceive(TranslationState.shared.subject) { event in
      let (eventPeer, enabled) = event
      guard eventPeer == peerId else { return }
      isTranslationEnabled = enabled
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

  private var infoForm: some View {
    VStack(spacing: 0) {
      ChatInfoDetailRow(title: "Chat ID") {
        if let chatId {
          Text(String(chatId))
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
        } else {
          Text("—")
            .foregroundStyle(.secondary)
        }
      }

      Divider()

      ChatInfoDetailRow(title: "Chat Type") {
        Text(chatTypeLabel)
      }

      Divider()

      ChatInfoDetailRow(title: "Notifications") {
        Picker("Notifications", selection: Binding(
          get: { notificationSelection },
          set: { newSelection in
            updateNotificationSettings(newSelection)
          }
        )) {
          Text(DialogNotificationSettingSelection.global.title).tag(DialogNotificationSettingSelection.global)
          Text(DialogNotificationSettingSelection.all.title).tag(DialogNotificationSettingSelection.all)
          Text(DialogNotificationSettingSelection.mentions.title).tag(DialogNotificationSettingSelection.mentions)
          Text(DialogNotificationSettingSelection.none.title).tag(DialogNotificationSettingSelection.none)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: 180)
      }

      if appSettings.translationUIEnabled {
        Divider()

        ChatInfoDetailRow(title: "Translation") {
          HStack(spacing: 10) {
            Toggle("", isOn: translationBinding)
              .labelsHidden()
              .toggleStyle(.switch)
              .accessibilityLabel("Translate messages")

            Button("Options") {
              showTranslationOptions = true
            }
            .foregroundStyle(.secondary)
            .buttonStyle(.link)
          }
        }
      }

      if shouldShowVisibilityRow {
        Divider()

        ChatInfoDetailRow(title: "Visibility") {
          HStack(spacing: 8) {
            Text(visibilityLabel)
              .foregroundStyle(canToggleVisibility ? .primary : .secondary)

            Toggle("", isOn: visibilityBinding)
              .labelsHidden()
              .accessibilityLabel("Visibility")
              .toggleStyle(.switch)
              .disabled(!canToggleVisibility)
          }
        }
      }
    }
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(Color(nsColor: .windowBackgroundColor))
        .shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 2)
    )
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 16)
    .sheet(isPresented: $showVisibilityPicker) {
      if let chat = fullChat.chat,
         let spaceId = chat.spaceId,
         let dependencies
      {
        ChatVisibilityParticipantsSheet(
          spaceId: spaceId,
          selectedUserIds: $selectedParticipantIds,
          db: dependencies.database,
          isPresented: $showVisibilityPicker,
          onConfirm: { participantIds in
            updateVisibility(isPublic: false, participantIds: Array(participantIds))
          }
        )
      }
    }
    .sheet(isPresented: $showTranslationOptions) {
      TranslationOptions(peer: peerId)
    }
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

  private func syncTranslationState() {
    isTranslationEnabled = TranslationState.shared.isTranslationEnabled(for: peerId)
  }

  private func loadVisibilityPermissions() async {
    guard peerId.isThread else {
      isOwnerOrAdmin = false
      return
    }
    guard let dependencies,
          let chat = fullChat.chat,
          let spaceId = chat.spaceId,
          let currentUserId = dependencies.auth.currentUserId
    else {
      isOwnerOrAdmin = false
      isCreator = false
      return
    }

    do {
      let member = try await dependencies.database.dbWriter.read { db in
        try Member
          .filter(Column("spaceId") == spaceId)
          .filter(Column("userId") == currentUserId)
          .fetchOne(db)
      }
      isOwnerOrAdmin = member?.role == .owner || member?.role == .admin
      isCreator = chat.createdBy == currentUserId
    } catch {
      isOwnerOrAdmin = false
      isCreator = false
      Log.shared.error("Failed to load chat permissions", error: error)
    }
  }

  private func handleVisibilityToggle(_ isPublic: Bool) {
    guard canToggleVisibility,
          let chat = fullChat.chat
    else { return }

    let currentlyPublic = chat.isPublic == true
    guard isPublic != currentlyPublic else { return }

    if isPublic {
      updateVisibility(isPublic: true, participantIds: [])
    } else {
      guard let currentUserId = dependencies?.auth.currentUserId else { return }
      selectedParticipantIds = [currentUserId]
      showVisibilityPicker = true
    }
  }

  private func updateVisibility(isPublic: Bool, participantIds: [Int64]) {
    guard case let .thread(chatId) = peerId else { return }

    Task {
      do {
        _ = try await Api.realtime.send(.updateChatVisibility(
          chatID: chatId,
          isPublic: isPublic,
          participantIDs: participantIds
        ))
        do {
          try await Api.realtime.send(.getChatParticipants(chatID: chatId))
        } catch {
          Log.shared.error("Failed to refetch chat participants after visibility update", error: error)
        }
      } catch {
        Log.shared.error("Failed to update chat visibility", error: error)
      }
    }
  }

  private func updateNotificationSettings(_ selection: DialogNotificationSettingSelection) {
    guard selection != notificationSelection else { return }

    Task {
      do {
        _ = try await realtimeV2.send(.updateDialogNotificationSettings(peerId: peerId, selection: selection))
      } catch {
        Log.shared.error("Failed to update dialog notification settings", error: error)
      }
    }
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

private struct ChatInfoDetailRow<Content: View>: View {
  let title: String
  @ViewBuilder let content: () -> Content

  var body: some View {
    HStack(spacing: 12) {
      Text(title)
        .foregroundStyle(.secondary)

      Spacer()

      content()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
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
