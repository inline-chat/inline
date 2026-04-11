import GRDB
import AppKit
import InlineKit
import InlineUI
import Logger
import SwiftUI
import Translation

struct ChatInfo: View {
  @Environment(\.dependencies) private var dependencies
  @Environment(\.realtimeV2) private var realtimeV2
  @EnvironmentStateObject var fullChat: FullChatViewModel
  @EnvironmentStateObject private var documentsState: ChatInfoDocumentsState
  @EnvironmentStateObject private var linksState: ChatInfoLinksState
  @EnvironmentStateObject private var participantsState: ChatInfoParticipantsState
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

  private var shouldShowParticipantsTab: Bool {
    chatId != nil
  }

  private var availableTabs: [ChatInfoTab] {
    var tabs: [ChatInfoTab] = [.files, .media, .links]
    if shouldShowParticipantsTab {
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
    _linksState = EnvironmentStateObject { env in
      ChatInfoLinksState(db: env.appDatabase, peer: peerId)
    }
    _participantsState = EnvironmentStateObject { env in
      ChatInfoParticipantsState(db: env.appDatabase)
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        header
        infoCard

        Picker("Tabs", selection: $selectedTab) {
          ForEach(availableTabs, id: \.self) { tab in
            Text(tab.title).tag(tab)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)

        tabContent
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.top, 16)
      .padding(.bottom, 24)
      .padding(.horizontal, 16)
    }
    .frame(maxWidth: .infinity, alignment: .top)
    .onAppear {
      updateViewModels()
      ensureSelectedTab()
      syncTranslationState()
    }
    .task(id: permissionsTaskKey) {
      await loadVisibilityPermissions()
    }
    .onChange(of: chatId) { _, _ in
      updateViewModels()
    }
    .onChange(of: availableTabsKey) { _, _ in
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
        .font(.title3)
        .fontWeight(.semibold)

      Text(chatTypeLabel)
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
  }

  private var infoCard: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 0) {
        infoRow("Chat ID") {
          if let chatId {
            Button {
              copyThreadIdToClipboard(chatId)
            } label: {
              Label {
                Text(String(chatId))
                  .font(.system(.body, design: .monospaced))
              } icon: {
                Image(systemName: "doc.on.doc")
                  .foregroundStyle(.secondary)
              }
            }
            .buttonStyle(.plain)
          } else {
            Text("—")
              .foregroundStyle(.secondary)
          }
        }

        Divider()

        infoRow("Chat Type") {
          Text(chatTypeLabel)
            .foregroundStyle(.secondary)
        }

        Divider()

        infoRow("Notifications") {
          Picker(
            "Notifications",
            selection: Binding(
              get: { notificationSelection },
              set: { newSelection in
                updateNotificationSettings(newSelection)
              }
            )
          ) {
            Text(DialogNotificationSettingSelection.global.title).tag(DialogNotificationSettingSelection.global)
            Text(DialogNotificationSettingSelection.all.title).tag(DialogNotificationSettingSelection.all)
            Text(DialogNotificationSettingSelection.mentions.title).tag(DialogNotificationSettingSelection.mentions)
            Text(DialogNotificationSettingSelection.none.title).tag(DialogNotificationSettingSelection.none)
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .frame(maxWidth: 220, alignment: .trailing)
        }

        if appSettings.translationUIEnabled {
          Divider()

          infoRow("Translation") {
            HStack(spacing: 10) {
              Toggle("Translate messages", isOn: translationBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Translate messages")

              Button("Options…") {
                showTranslationOptions = true
              }
              .buttonStyle(.link)
            }
          }
        }

        if shouldShowVisibilityRow {
          Divider()

          infoRow("Visibility") {
            HStack(spacing: 8) {
              Text(visibilityLabel)
                .foregroundStyle(canToggleVisibility ? .primary : .secondary)

              Toggle("Visibility", isOn: visibilityBinding)
                .labelsHidden()
                .accessibilityLabel("Visibility")
                .toggleStyle(.switch)
                .disabled(!canToggleVisibility)
            }
          }

          if !canToggleVisibility {
            Text("Only the chat creator, owner, or admin can change visibility.")
              .font(.footnote)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.leading, 154)
              .padding(.bottom, 8)
          }
        }
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      Label("Info", systemImage: "info.circle")
        .font(.headline)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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
  private func infoRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    HStack(alignment: .center, spacing: 12) {
      Text(title)
        .foregroundStyle(.secondary)
        .frame(width: 140, alignment: .leading)

      Spacer(minLength: 0)

      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 10)
    .padding(.horizontal, 2)
  }

  @ViewBuilder
  private var tabContent: some View {
    switch selectedTab {
      case .files:
        filesTab
      case .media:
        comingSoonView(title: "Media", message: "Media browsing is coming soon.")
      case .links:
        linksTab
      case .participants:
        participantsTab
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

  @ViewBuilder
  private var linksTab: some View {
    if let linksViewModel = linksState.linksViewModel {
      ChatInfoLinksList(linksViewModel: linksViewModel)
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

  @ViewBuilder
  private var participantsTab: some View {
    if let participantsViewModel = participantsState.participantsViewModel {
      ChatInfoParticipantsList(
        participantsViewModel: participantsViewModel,
        currentUserId: dependencies?.auth.currentUserId
      )
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

  private func updateViewModels() {
    guard let chatId, chatId > 0 else { return }
    documentsState.updateChatId(chatId)
    linksState.updateChatId(chatId)
    participantsState.updateChatId(chatId)
  }

  private func syncTranslationState() {
    isTranslationEnabled = TranslationState.shared.isTranslationEnabled(for: peerId)
  }

  private func copyThreadIdToClipboard(_ threadId: Int64) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(String(threadId), forType: .string)
    ToastCenter.shared.showSuccess("Copied chat ID")
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

@MainActor
private final class ChatInfoLinksState: ObservableObject {
  @Published private(set) var linksViewModel: ChatLinksViewModel?

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
    linksViewModel = ChatLinksViewModel(db: db, chatId: chatId, peer: peer)
  }
}

@MainActor
private final class ChatInfoParticipantsState: ObservableObject {
  @Published private(set) var participantsViewModel: ChatParticipantsWithMembersViewModel?

  private let db: AppDatabase
  private var currentChatId: Int64 = 0

  init(db: AppDatabase) {
    self.db = db
  }

  func updateChatId(_ chatId: Int64) {
    guard chatId > 0 else { return }
    guard chatId != currentChatId else { return }
    currentChatId = chatId
    participantsViewModel = ChatParticipantsWithMembersViewModel(
      db: db,
      chatId: chatId,
      purpose: .participantsList
    )
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
              Text(chatInfoDateLabel(group.date))
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
}

private struct ChatInfoLinksList: View {
  @ObservedObject var linksViewModel: ChatLinksViewModel

  var body: some View {
    Group {
      if linksViewModel.linkMessages.isEmpty {
        Text("No links found in this chat.")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.vertical, 32)
      } else {
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach(linksViewModel.groupedLinkMessages, id: \.date) { group in
            VStack(alignment: .leading, spacing: 8) {
              Text(chatInfoDateLabel(group.date))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

              ForEach(group.messages, id: \.id) { linkMessage in
                ChatInfoLinkRow(linkMessage: linkMessage)
                  .onAppear {
                    Task {
                      await linksViewModel.loadMoreIfNeeded(currentMessageId: linkMessage.message.messageId)
                    }
                  }
              }
            }
            .padding(.horizontal, 16)
          }
        }
      }
    }
    .task {
      await linksViewModel.loadInitial()
    }
  }
}

private struct ChatInfoLinkRow: View {
  let linkMessage: LinkMessage
  @Environment(\.openURL) private var openURL

  private static let detector: NSDataDetector? = {
    try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
  }()

  private var url: URL? {
    parseURL(linkMessage.urlPreview?.url) ?? firstURL(from: linkMessage.message.text)
  }

  private var title: String {
    if let title = linkMessage.urlPreview?.title?.trimmingCharacters(in: .whitespacesAndNewlines),
       !title.isEmpty
    {
      return title
    }
    if let host = url?.host, !host.isEmpty {
      return host
    }
    if let text = linkMessage.message.text?.trimmingCharacters(in: .whitespacesAndNewlines),
       !text.isEmpty
    {
      return text
    }
    return "Link"
  }

  private var subtitle: String? {
    if let absolute = url?.absoluteString, !absolute.isEmpty {
      return absolute
    }
    if let text = linkMessage.message.text?.trimmingCharacters(in: .whitespacesAndNewlines),
       !text.isEmpty
    {
      return text
    }
    return nil
  }

  var body: some View {
    Button {
      guard let url else { return }
      openURL(url)
    } label: {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "link")
          .foregroundStyle(.secondary)
          .font(.system(size: 12, weight: .semibold))
          .padding(.top, 2)

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.body)
            .foregroundStyle(.primary)
            .lineLimit(1)

          if let subtitle {
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }

        Spacer(minLength: 8)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(Color(nsColor: .windowBackgroundColor))
      )
    }
    .buttonStyle(.plain)
    .disabled(url == nil)
  }

  private func parseURL(_ rawValue: String?) -> URL? {
    guard let rawValue else { return nil }
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let url = URL(string: trimmed),
       let scheme = url.scheme?.lowercased(),
       ["http", "https"].contains(scheme)
    {
      return url
    }

    if let url = URL(string: "https://\(trimmed)"),
       let scheme = url.scheme?.lowercased(),
       ["http", "https"].contains(scheme)
    {
      return url
    }

    return nil
  }

  private func firstURL(from text: String?) -> URL? {
    guard let text, !text.isEmpty, let detector = Self.detector else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    var foundURL: URL?

    detector.enumerateMatches(in: text, options: [], range: range) { match, _, stop in
      guard let matchURL = match?.url else { return }
      if let parsedURL = parseURL(matchURL.absoluteString) {
        foundURL = parsedURL
        stop.pointee = true
      }
    }

    return foundURL
  }
}

private struct ChatInfoParticipantsList: View {
  @ObservedObject var participantsViewModel: ChatParticipantsWithMembersViewModel
  let currentUserId: Int64?

  private var sortedParticipants: [UserInfo] {
    participantsViewModel.participants.sorted { lhs, rhs in
      let lhsName = lhs.user.displayName.lowercased()
      let rhsName = rhs.user.displayName.lowercased()
      if lhsName == rhsName {
        return lhs.user.id < rhs.user.id
      }
      return lhsName < rhsName
    }
  }

  var body: some View {
    Group {
      if sortedParticipants.isEmpty {
        Text("No participants found in this chat.")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.vertical, 32)
      } else {
        VStack(alignment: .leading, spacing: 10) {
          Text("\(sortedParticipants.count) participant\(sortedParticipants.count == 1 ? "" : "s")")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)

          LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(sortedParticipants, id: \.id) { participant in
              HStack(spacing: 10) {
                UserAvatar(user: participant.user, size: 26)

                VStack(alignment: .leading, spacing: 1) {
                  HStack(spacing: 6) {
                    Text(participant.user.displayName)
                      .font(.body)
                      .lineLimit(1)

                    if participant.user.id == currentUserId {
                      Text("You")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    }
                  }

                  if let username = participant.user.username, !username.isEmpty {
                    Text("@\(username)")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                  }
                }

                Spacer(minLength: 8)
              }
              .padding(.horizontal, 10)
              .padding(.vertical, 7)
              .background(
                RoundedRectangle(cornerRadius: 10)
                  .fill(Color(nsColor: .windowBackgroundColor))
              )
            }
          }
        }
        .padding(.horizontal, 16)
      }
    }
    .task {
      await participantsViewModel.refetchParticipants()
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

private func chatInfoDateLabel(_ date: Date) -> String {
  let calendar = Calendar.current
  let now = Date()

  if calendar.isDateInToday(date) {
    return "Today"
  }
  if calendar.isDateInYesterday(date) {
    return "Yesterday"
  }
  if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE"
    return formatter.string(from: date)
  }

  let formatter = DateFormatter()
  formatter.dateFormat = "MMMM d, yyyy"
  return formatter.string(from: date)
}

// TODO: Previews
