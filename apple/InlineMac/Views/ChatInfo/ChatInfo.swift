import GRDB
import AppKit
import InlineKit
import InlineUI
import Logger
import Nuke
import Quartz
import SwiftUI
import Translation

enum ChatInfoDefaultTab: Hashable {
  case files
  case media
  case links
  case participants
}

private enum ChatVisibilitySelection: String, CaseIterable, Hashable {
  case publicChat
  case privateChat

  var title: String {
    switch self {
      case .publicChat:
        "Public"
      case .privateChat:
        "Private"
    }
  }
}

struct ChatInfo: View {
  @Environment(\.dependencies) private var dependencies
  @Environment(\.nav) private var nav
  @Environment(\.realtimeV2) private var realtimeV2
  @EnvironmentStateObject var fullChat: FullChatViewModel
  @EnvironmentStateObject private var documentsState: ChatInfoDocumentsState
  @EnvironmentStateObject private var linksState: ChatInfoLinksState
  @EnvironmentStateObject private var participantsState: ChatInfoParticipantsState
  @StateObject private var appSettings = AppSettings.shared
  @StateObject private var avatarPreview = ChatInfoAvatarQuickLookPresenter()

  let peerId: Peer
  private let defaultTab: ChatInfoDefaultTab?
  @State private var selectedTab: ChatInfoTab = .files
  @State private var didApplyDefaultTab = false
  @State private var isOwnerOrAdmin = false
  @State private var isCreator = false
  @State private var showVisibilityPicker = false
  @State private var showTranslationOptions = false
  @State private var showAddParticipants = false
  @State private var showRemoveParticipantConfirmation = false
  @State private var isTranslationEnabled: Bool
  @State private var selectedParticipantIds: Set<Int64> = []
  @State private var participantPendingRemoval: UserInfo?

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

  private var notificationSelection: DialogNotificationSettingSelection {
    fullChat.chatItem?.dialog.notificationSelection ?? .global
  }

  private var notificationTitle: String {
    notificationSelection == .global ? "Default" : notificationSelection.title
  }

  private var visibilitySelection: ChatVisibilitySelection {
    fullChat.chat?.isPublic == true ? .publicChat : .privateChat
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
    peerId.isThread && chatId != nil && fullChat.chat?.type != .privateChat
  }

  private var canManageParticipants: Bool {
    guard peerId.isThread,
          let chat = fullChat.chat,
          chat.isPublic == false
    else {
      return false
    }
    return isOwnerOrAdmin || isCreator
  }

  private var availableTabs: [ChatInfoTab] {
    var tabs: [ChatInfoTab] = []
    if shouldShowParticipantsTab {
      tabs.append(.participants)
    }
    tabs.append(contentsOf: [.files, .links])
    return tabs
  }

  private var availableTabsKey: String {
    availableTabs.map(\.title).joined(separator: "|")
  }

  private var permissionsTaskKey: String {
    "\(peerId.toString())-\(fullChat.chat?.id ?? 0)-\(fullChat.chat?.spaceId ?? 0)-\(fullChat.chat?.createdBy ?? 0)-\(dependencies?.auth.currentUserId ?? 0)"
  }

  public init(peerId: Peer, defaultTab: ChatInfoDefaultTab? = nil) {
    self.peerId = peerId
    self.defaultTab = defaultTab
    _selectedTab = State(initialValue: ChatInfoTab(defaultTab))
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
      .padding(.top, 24)
      .padding(.bottom, 24)
      .padding(.horizontal, 16)
    }
    .frame(maxWidth: .infinity, alignment: .top)
    .navigationTitle(chatTitle)
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
      updateViewModels()
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
      Button {
        avatarPreview.show(userInfo: userInfo)
      } label: {
        ChatIcon(peer: .user(userInfo), size: 100)
      }
      .buttonStyle(.plain)
      .contentShape(Circle())
      .help("Open avatar")
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
        .padding(.top, 4)

      Text(chatTitle)
        .font(.title3)
        .fontWeight(.semibold)
    }
    .frame(maxWidth: .infinity)
  }

  private var infoCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      GroupBox {
        VStack(alignment: .leading, spacing: 0) {
          if let username = fullChat.chatItem?.userInfo?.user.username, !username.isEmpty {
            infoRow("Username") {
              Text("@\(username)")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }

            Divider()
          }

          infoRow("Notifications") {
            notificationPicker
          }

          if appSettings.translationUIEnabled {
            Divider()

            infoRow("Translation") {
              HStack(spacing: 10) {
                Toggle("Translate messages", isOn: translationBinding)
                  .labelsHidden()
                  .toggleStyle(.switch)
                  .accessibilityLabel("Translate messages")

                Button {
                  showTranslationOptions = true
                } label: {
                  Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15, weight: .regular))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Translation options")
                .help("Translation options")
              }
            }
          }

          if shouldShowVisibilityRow {
            Divider()

            infoRow("Visibility") {
              visibilityPicker
            }
          }

          Divider()

          infoRow("Chat ID") {
            if let chatId {
              Button {
                copyThreadIdToClipboard(chatId)
              } label: {
                Text(String(chatId))
                  .font(.system(.body, design: .monospaced))
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Copy chat ID")
            } else {
              Text("—")
                .foregroundStyle(.secondary)
            }
          }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      if shouldShowVisibilityRow, !canToggleVisibility {
        Text("Only the chat creator, owner, or admin can change visibility.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 4)
      }
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
    .sheet(isPresented: $showAddParticipants) {
      if let chat = fullChat.chat, let dependencies {
        if let spaceId = chat.spaceId {
          AddParticipantsSheet(
            chatId: chat.id,
            spaceId: spaceId,
            currentParticipants: participantsState.participantsViewModel?.participants ?? [],
            db: dependencies.database,
            isPresented: $showAddParticipants
          )
        } else {
          AddHomeParticipantsSheet(
            chatId: chat.id,
            currentUserId: dependencies.auth.currentUserId,
            currentParticipants: participantsState.participantsViewModel?.participants ?? [],
            db: dependencies.database,
            isPresented: $showAddParticipants
          )
        }
      }
    }
    .confirmationDialog(
      "Remove participant?",
      isPresented: $showRemoveParticipantConfirmation,
      presenting: participantPendingRemoval,
      actions: { participant in
        Button("Cancel", role: .cancel) {}
        Button("Remove", role: .destructive) {
          removeParticipant(userId: participant.user.id)
        }
      },
      message: { participant in
        Text("Remove \(participant.user.shortDisplayName) from this chat?")
      }
    )
  }

  private var notificationPicker: some View {
    Menu {
      ForEach(DialogNotificationSettingSelection.allCases, id: \.self) { selection in
        Button {
          updateNotificationSettings(selection)
        } label: {
          Label(notificationTitle(for: selection), systemImage: selection.iconName)
        }
      }
    } label: {
      InlineMenuPickerLabel(
        title: notificationTitle,
        systemImage: notificationSelection.iconName,
        disabled: false
      )
    }
    .menuStyle(.borderlessButton)
    .buttonStyle(.plain)
    .accessibilityLabel("Notifications")
  }

  private func notificationTitle(for selection: DialogNotificationSettingSelection) -> String {
    selection == .global ? "Default" : selection.title
  }

  private var visibilityPicker: some View {
    Menu {
      ForEach(ChatVisibilitySelection.allCases, id: \.self) { selection in
        Button(selection.title) {
          handleVisibilitySelection(selection)
        }
      }
    } label: {
      InlineMenuPickerLabel(
        title: visibilitySelection.title,
        systemImage: "eye",
        disabled: !canToggleVisibility
      )
    }
    .menuStyle(.borderlessButton)
    .buttonStyle(.plain)
    .disabled(!canToggleVisibility)
    .accessibilityLabel("Visibility")
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
    .padding(.vertical, 8)
    .padding(.horizontal, 10)
  }

  @ViewBuilder
  private var tabContent: some View {
    switch selectedTab {
      case .files:
        filesTab
      case .media:
        filesTab
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
        currentUserId: dependencies?.auth.currentUserId,
        canManageParticipants: canManageParticipants,
        onAddParticipants: {
          showAddParticipants = true
        },
        onOpenChatInfo: { userInfo in
          openUserChatInfo(userInfo)
        },
        onRequestRemove: { userInfo in
          participantPendingRemoval = userInfo
          showRemoveParticipantConfirmation = true
        }
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
    if !didApplyDefaultTab {
      let preferredTab = ChatInfoTab(defaultTab)
      if availableTabs.contains(preferredTab) {
        selectedTab = preferredTab
        didApplyDefaultTab = true
        return
      }
    }

    guard availableTabs.contains(selectedTab) else {
      selectedTab = availableTabs.first ?? .files
      return
    }
  }

  private func updateViewModels() {
    guard let chatId, chatId > 0 else { return }
    documentsState.updateChatId(chatId)
    linksState.updateChatId(chatId)
    if shouldShowParticipantsTab {
      participantsState.updateChatId(chatId)
    }
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
          let currentUserId = dependencies.auth.currentUserId
    else {
      isOwnerOrAdmin = false
      isCreator = false
      return
    }

    isCreator = chat.createdBy == currentUserId
    guard let spaceId = chat.spaceId else {
      isOwnerOrAdmin = false
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
    } catch {
      isOwnerOrAdmin = false
      Log.shared.error("Failed to load chat permissions", error: error)
    }
  }

  private func handleVisibilitySelection(_ selection: ChatVisibilitySelection) {
    guard canToggleVisibility,
          let chat = fullChat.chat
    else { return }

    let currentlyPublic = chat.isPublic == true
    let isPublic = selection == .publicChat
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

  private func removeParticipant(userId: Int64) {
    guard case let .thread(chatId) = peerId else { return }
    if let currentUserId = dependencies?.auth.currentUserId, currentUserId == userId { return }

    Task {
      do {
        _ = try await Api.realtime.send(.removeChatParticipant(chatID: chatId, userID: userId))
        do {
          try await Api.realtime.send(.getChatParticipants(chatID: chatId))
        } catch {
          Log.shared.error("Failed to refetch chat participants after removal", error: error)
        }
      } catch {
        Log.shared.error("Failed to remove participant", error: error)
      }
    }
  }

  private func openUserChatInfo(_ userInfo: UserInfo) {
    let peer = Peer.user(id: userInfo.user.id)
    if let dependencies {
      dependencies.openChatInfo(peer: peer)
    } else {
      nav.open(.chatInfo(peer: peer))
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

  init(_ tab: ChatInfoDefaultTab?) {
    switch tab {
    case .none:
      self = .participants
    case .participants:
      self = .participants
    case .files:
      self = .files
    case .media:
      self = .files
    case .links:
      self = .links
    }
  }

  var title: String {
    rawValue.capitalized
  }
}

private struct InlineMenuPickerLabel: View {
  let title: String
  let systemImage: String
  let disabled: Bool

  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: systemImage)
        .font(.system(size: 12, weight: .regular))
        .frame(width: 14)

      Text(title)
        .lineLimit(1)

      Image(systemName: "chevron.up.chevron.down")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.tertiary)
    }
    .foregroundStyle(disabled ? .secondary : .primary)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }
}

private final class ChatInfoAvatarQuickLookPresenter: NSObject, ObservableObject {
  private var item: ChatInfoAvatarPreviewItem?
  private var tempURL: URL?
  private var isLoading = false

  func show(userInfo: UserInfo) {
    Task { @MainActor in
      await open(userInfo: userInfo)
    }
  }

  @MainActor
  private func open(userInfo: UserInfo) async {
    guard !isLoading else { return }

    let user = userInfo.user
    let title = user.displayName.isEmpty ? "Avatar" : user.displayName

    if let localURL = user.getLocalURL(), FileManager.default.fileExists(atPath: localURL.path) {
      present(url: localURL, title: title, ownsTempURL: false)
      return
    }

    guard let remoteURL = user.getRemoteURL() else {
      ToastCenter.shared.showError("Avatar isn't available")
      return
    }

    isLoading = true
    defer { isLoading = false }

    do {
      let image = try await ImagePipeline.shared.image(for: ImageRequest(url: remoteURL))
      let previewURL = try makeTempURL(for: image)
      present(url: previewURL, title: title, ownsTempURL: true)
    } catch {
      ToastCenter.shared.showError("Failed to open avatar")
    }
  }

  @MainActor
  private func present(url: URL, title: String, ownsTempURL: Bool) {
    if !ownsTempURL {
      cleanupTempURL()
    }

    item = ChatInfoAvatarPreviewItem(url: url, title: title)

    guard let panel = QLPreviewPanel.shared() else {
      return
    }

    panel.dataSource = self
    panel.delegate = self
    panel.reloadData()
    setLargeFrame(for: panel)
    panel.makeKeyAndOrderFront(nil)
  }

  private func makeTempURL(for image: NSImage) throws -> URL {
    cleanupTempURL()

    guard let data = image.tiffRepresentation else {
      throw ChatInfoAvatarPreviewError.imageEncodingFailed
    }

    let dir = try FileManager.default.url(
      for: .itemReplacementDirectory,
      in: .userDomainMask,
      appropriateFor: FileManager.default.temporaryDirectory,
      create: true
    )
    let url = dir.appending(path: "avatar-\(UUID().uuidString).tiff")
    try data.write(to: url, options: .atomic)
    tempURL = url
    return url
  }

  private func setLargeFrame(for panel: QLPreviewPanel) {
    guard let visibleFrame = NSScreen.main?.visibleFrame else {
      return
    }

    let width = min(max(720, visibleFrame.width * 0.52), visibleFrame.width - 80)
    let height = min(max(720, visibleFrame.height * 0.72), visibleFrame.height - 80)
    let frame = NSRect(
      x: visibleFrame.midX - width / 2,
      y: visibleFrame.midY - height / 2,
      width: width,
      height: height
    )
    panel.setFrame(frame, display: true, animate: true)
  }

  private func cleanupTempURL() {
    guard let tempURL else { return }
    try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
    self.tempURL = nil
  }

  deinit {
    cleanupTempURL()
  }
}

extension ChatInfoAvatarQuickLookPresenter: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    item == nil ? 0 : 1
  }

  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
    item
  }
}

private final class ChatInfoAvatarPreviewItem: NSObject, QLPreviewItem {
  let url: URL
  let title: String

  init(url: URL, title: String) {
    self.url = url
    self.title = title
  }

  @objc var previewItemURL: URL? {
    url
  }

  var previewItemTitle: String? {
    title
  }
}

private enum ChatInfoAvatarPreviewError: Error {
  case imageEncodingFailed
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
  let canManageParticipants: Bool
  let onAddParticipants: () -> Void
  let onOpenChatInfo: (UserInfo) -> Void
  let onRequestRemove: (UserInfo) -> Void

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
        VStack(alignment: .leading, spacing: 0) {
          HStack {
            Text("\(sortedParticipants.count) participant\(sortedParticipants.count == 1 ? "" : "s")")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.secondary)

            Spacer()

            if canManageParticipants {
              Button {
                onAddParticipants()
              } label: {
                Label("Add", systemImage: "person.badge.plus")
              }
              .buttonStyle(.borderless)
              .controlSize(.small)
            }
          }
          .padding(.horizontal, 16)
          .padding(.bottom, 8)

          VStack(alignment: .leading, spacing: 0) {
            ForEach(sortedParticipants, id: \.id) { participant in
              ChatInfoParticipantRow(
                participant: participant,
                isCurrentUser: participant.user.id == currentUserId,
                canRemove: canManageParticipants && participant.user.id != currentUserId,
                onOpenChatInfo: {
                  onOpenChatInfo(participant)
                },
                onRequestRemove: {
                  onRequestRemove(participant)
                }
              )

              if participant.id != sortedParticipants.last?.id {
                Divider()
                  .padding(.leading, 54)
              }
            }
          }
          .background(Color(nsColor: .controlBackgroundColor))
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
          }
          .padding(.horizontal, 16)
        }
      }
    }
    .task {
      await participantsViewModel.refetchParticipants()
    }
  }
}

private struct ChatInfoParticipantRow: View {
  let participant: UserInfo
  let isCurrentUser: Bool
  let canRemove: Bool
  let onOpenChatInfo: () -> Void
  let onRequestRemove: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      HStack(spacing: 10) {
        Button(action: onOpenChatInfo) {
          UserAvatar(user: participant.user, size: 28)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .help("Open User Info")

        VStack(alignment: .leading, spacing: 1) {
          HStack(spacing: 6) {
            Text(participant.user.displayName)
              .font(.body)
              .foregroundStyle(.primary)
              .lineLimit(1)

            if isCurrentUser {
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
      .frame(maxWidth: .infinity, alignment: .leading)

      if canRemove {
        Button(role: .destructive, action: onRequestRemove) {
          Image(systemName: "minus.circle")
            .font(.system(size: 14, weight: .medium))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Remove participant")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .contentShape(Rectangle())
    .contextMenu {
      if canRemove {
        Button(role: .destructive, action: onRequestRemove) {
          Label("Remove Participant", systemImage: "minus.circle")
        }
      }
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
