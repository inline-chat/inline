import Auth
import Combine
import InlineCompatUI
import InlineIOSFoundation
import InlineKit
import InlineUI
import Logger
import RealtimeV2
import UIKit

/// UIKit chat info, for systems where the SwiftUI `ChatInfoView` isn't bridged (iOS 15+).
/// Port of `ChatInfoView`: header, person fields, thread place and visibility, members with
/// add/remove, notifications, follow, pin, archive, copy link, and leave/delete.
///
/// Not ported: media/files/links/voice tabs, subthreads list, bots and agent settings,
/// translation, delete history, group adding, emoji picker (a text field takes one emoji),
/// developer IDs.
@MainActor
final class ChatInfoViewController: FormViewController {
  private let initialItem: SpaceChatItem
  private unowned let shell: MainShellController
  private let startsEditing: Bool
  private var didStartEditing = false

  private let chatViewModel: FullChatViewModel
  /// Threads only.
  private let participants: ChatParticipantsWithMembersViewModel?
  /// Space threads only: roles and permissions.
  private let spaceMembers: SpaceMembersViewModel?
  /// Space threads only: the space and its members with users (pickers).
  private let spaceFullMembers: SpaceFullMembersViewModel?

  private var cancellables: Set<AnyCancellable> = []
  private var refreshTask: Task<Void, Never>?
  private var pendingNotificationSelection: DialogNotificationSettingSelection?
  private var notificationGeneration: UInt64 = 0
  private var pendingFollow: Bool?
  private var isSavingInfo = false
  private var barState: BarState?

  private var router: Router { shell.router }

  init(chatItem: SpaceChatItem, shell: MainShellController, editing: Bool) {
    initialItem = chatItem
    self.shell = shell
    startsEditing = editing
    let db = AppDatabase.shared
    chatViewModel = FullChatViewModel(db: db, peer: chatItem.peerId, initialChatItem: chatItem)
    if chatItem.peerId.isThread {
      participants = ChatParticipantsWithMembersViewModel(
        db: db,
        chatId: chatItem.chat?.id ?? chatItem.dialog.chatId ?? 0
      )
    } else {
      participants = nil
    }
    if !chatItem.peerId.isPrivate, let spaceId = chatItem.chat?.spaceId {
      spaceMembers = SpaceMembersViewModel(db: db, spaceId: spaceId)
      spaceFullMembers = SpaceFullMembersViewModel(db: db, spaceId: spaceId)
    } else {
      spaceMembers = nil
      spaceFullMembers = nil
    }
    super.init(style: .insetGrouped)
    title = String(localized: "Info")
    hidesBottomBarWhenPushed = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit {
    refreshTask?.cancel()
  }

  /// A page sheet holding chat info, for `MainShellController.presentChatInfo` on iOS 15–17.
  static func sheet(chatItem: SpaceChatItem, shell: MainShellController, editing: Bool) -> UIViewController {
    let root = ChatInfoViewController(chatItem: chatItem, shell: shell, editing: editing)
    let navigation = SheetNavigationController(root: root, showsCancel: false)
    navigation.modalPresentationStyle = .pageSheet
    navigation.compatConfigureSheet(detents: [.large], prefersGrabber: false)
    return navigation
  }

  // MARK: Lifecycle

  override func registerCells(in tableView: UITableView) {
    tableView.register(ChatInfoHeaderCell.self, forCellReuseIdentifier: ChatInfoHeaderCell.reuseIdentifier)
    tableView.register(ChatInfoPersonCell.self, forCellReuseIdentifier: ChatInfoPersonCell.reuseIdentifier)
    tableView.register(ChatInfoFieldCell.self, forCellReuseIdentifier: ChatInfoFieldCell.reuseIdentifier)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    navigationItem.largeTitleDisplayMode = .never
    navigationItem.backButtonDisplayMode = .minimal
    bind()
    refresh()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    updateBarItems()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if startsEditing, !didStartEditing {
      didStartEditing = true
      // Same gate as the chat's rename entry point.
      if subject.isThread, currentChat?.canUpdateInfo != false {
        presentRenamePrompt()
      }
    }
  }

  private func bind() {
    chatViewModel.chatItemPublisher
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.setNeedsFormUpdate() }
      .store(in: &cancellables)

    let models: [ObservableObjectPublisher] = [
      participants?.objectWillChange,
      spaceMembers?.objectWillChange,
      spaceFullMembers?.objectWillChange,
    ].compactMap { $0 }
    for publisher in models {
      publisher
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.setNeedsFormUpdate() }
        .store(in: &cancellables)
    }

    INUserSettings.current.notification.$mode
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.setNeedsFormUpdate() }
      .store(in: &cancellables)

    NotificationCenter.default.publisher(for: Notification.Name("chatDeletedNotification"))
      .receive(on: DispatchQueue.main)
      .sink { [weak self] notification in self?.handleChatDeleted(notification) }
      .store(in: &cancellables)
  }

  /// Same loads as `ChatInfoView.onAppear` and its `.task(id: peerId)`.
  private func refresh() {
    let peer = peer
    let needsChat = currentChatId <= 0
    let isDM = isDM
    let spaceMembers = spaceMembers
    let participants = participants
    refreshTask = Task {
      if needsChat {
        do {
          _ = try await Api.realtime.send(.getChat(peer: peer))
        } catch {
          Log.shared.error("Chat info failed to load chat", error: error)
        }
      }
      guard !isDM, !Task.isCancelled else { return }
      if let spaceMembers {
        await spaceMembers.refetchMembers()
      }
      await participants?.refetchParticipants()
    }
  }

  // MARK: State

  private var peer: Peer { initialItem.peerId }
  private var item: SpaceChatItem { chatViewModel.chatItem ?? initialItem }
  private var dialog: Dialog { item.dialog }
  private var currentChat: Chat? { item.chat ?? initialItem.chat }
  private var userInfo: UserInfo? { item.userInfo ?? initialItem.userInfo }
  private var currentChatId: Int64 { currentChat?.id ?? initialItem.dialog.chatId ?? 0 }
  private var isDM: Bool { peer.isPrivate }
  private var currentUserId: Int64? { Auth.shared.getCurrentUserId() }

  private var subject: PeerInfoSubject {
    PeerInfoSubject.resolve(peer: peer, chat: currentChat, user: userInfo?.user, currentUserId: currentUserId)
  }

  private var chatTitle: String {
    currentChat?.humanReadableTitle ?? initialItem.chat?.humanReadableTitle ?? "Chat"
  }

  private var currentMembership: Member? {
    guard let currentUserId else { return nil }
    return spaceMembers?.members.first { $0.userId == currentUserId }
  }

  private var isOwnerOrAdmin: Bool {
    currentMembership?.role == .owner || currentMembership?.role == .admin
  }

  private var memberRoles: [Int64: MemberRole] {
    Dictionary((spaceMembers?.members ?? []).map { ($0.userId, $0.role) }, uniquingKeysWith: { first, _ in first })
  }

  /// Anyone who can see a private thread may add people to it.
  private var canAddParticipants: Bool {
    ChatParticipantPolicy.canAdd(chat: currentChat)
  }

  /// Mirrors `ensureCanManageChatParticipants` on the server.
  private var canManageParticipants: Bool {
    guard currentChat?.isPublic == false else { return false }
    if let currentUserId, currentChat?.createdBy == currentUserId { return true }
    return currentChat?.spaceId != nil && isOwnerOrAdmin
  }

  private var canChangeVisibility: Bool {
    ChatVisibilityPolicy.canChange(chat: currentChat, currentUserId: currentUserId, membership: currentMembership)
  }

  private var canEditChatInfo: Bool {
    if let canUpdateInfo = currentChat?.canUpdateInfo { return canUpdateInfo }
    guard !isDM, let currentUserId else { return false }
    if currentChat?.isReplyThread == true, isOwnerOrAdmin { return true }
    if currentChat?.isPublic == true {
      return spaceMembers?.members.contains { $0.userId == currentUserId && $0.canAccessPublicChats } ?? false
    }
    if currentChat?.isReplyThread == true {
      return participants?.effectiveUserIds.contains(currentUserId) ?? false
    }
    return participants?.participants.contains { $0.user.id == currentUserId } ?? false
  }

  private var threadMemberCount: Int? {
    guard let participants else { return nil }
    let count = participants.effectiveUserIds.count
    if count > 0 { return count }
    return participants.participants.isEmpty ? nil : participants.participants.count
  }

  private var notificationSelection: DialogNotificationSettingSelection {
    pendingNotificationSelection ?? dialog.notificationSelection
  }

  private var isFollowing: Bool {
    pendingFollow ?? dialog.isFollowingThread
  }

  private var nextPinnedState: Bool? {
    if dialog.pinned == true { return false }
    let isInboxEligible = dialog.open && dialog.archived != true && dialog.chatListHidden != true
    return isInboxEligible ? true : nil
  }

  private var destructiveAction: ChatDestructiveAction? {
    ChatDestructiveActionResolver.action(peer: peer, chat: currentChat)
  }

  private var isInSheet: Bool {
    navigationController?.presentingViewController != nil
  }

  // MARK: Bar

  private struct BarState: Equatable {
    var showsClose: Bool
    var showsEdit: Bool
  }

  private func updateBarItems() {
    let state = BarState(
      showsClose: isInSheet && navigationController?.viewControllers.first === self,
      showsEdit: subject.isThread && canEditChatInfo
    )
    guard state != barState else { return }
    barState = state
    navigationItem.leftBarButtonItem = state.showsClose
      ? UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismissSheet() })
      : nil
    navigationItem.rightBarButtonItem = state.showsEdit
      ? UIBarButtonItem(title: String(localized: "Edit"), primaryAction: UIAction { [weak self] _ in self?.presentRenamePrompt() })
      : nil
  }

  // MARK: Sections

  @FormSectionsBuilder
  override func makeSections() -> [FormSection] {
    let info = self.subject
    let _ = updateBarItems()
    FormSection("header") {
      headerRow(subject: info)
    }
    if info.isDirect {
      directSections(subject: info)
    } else {
      threadSections(subject: info)
    }
    commonSections()
  }

  private func headerRow(subject: PeerInfoSubject) -> FormRow {
    let identity: ChatInfoHeaderCell.Identity
    let title: String
    let subtitle: String?
    var onIconTap: (@MainActor () -> Void)?

    if subject.isDirect, let userInfo {
      identity = .user(userInfo)
      title = userInfo.user.fullName.isEmpty ? userInfo.user.displayName : userInfo.user.fullName
      subtitle = directSubtitle(subject: subject, userInfo: userInfo)
    } else {
      identity = .thread(
        currentChat.map(ThreadIconDescriptor.init(chat:))
          ?? ThreadIconDescriptor(emoji: nil, title: chatTitle, accessibilityLabel: chatTitle)
      )
      title = chatTitle
      let kind = PeerInfoSubtitle.thread(subject: subject, memberCount: threadMemberCount)
      subtitle = [spaceFullMembers?.space?.displayName, kind].compactMap { $0 }.joined(separator: " · ")
      if subject.isThread, canEditChatInfo {
        onIconTap = { [weak self] in self?.presentRenamePrompt() }
      }
    }

    let key = HeaderKey(identity: identity, title: title, subtitle: subtitle, isIconTappable: onIconTap != nil)
    let tap = onIconTap
    return FormRow.custom("header", reuseIdentifier: ChatInfoHeaderCell.reuseIdentifier, contentKey: key) { cell in
      (cell as? ChatInfoHeaderCell)?.configure(identity: identity, title: title, subtitle: subtitle, onIconTap: tap)
    }
  }

  private func directSubtitle(subject: PeerInfoSubject, userInfo: UserInfo) -> String? {
    let fields = PeerInfoPersonFields(user: userInfo.user)
    switch subject.kind {
    case .selfChat:
      return String(localized: "Only you can see this chat")
    case .bot:
      return fields.username.map { "@\($0)" } ?? String(localized: "bot")
    default:
      let status = PeerInfoSubtitle.person(
        focusActive: userInfo.focus?.isActive() == true,
        localTime: fields.localTime
      )
      let line = [fields.username.map { "@\($0)" }, status].compactMap { $0 }.joined(separator: " · ")
      return line.isEmpty ? nil : line
    }
  }

  // MARK: Direct

  @FormSectionsBuilder
  private func directSections(subject: PeerInfoSubject) -> [FormSection] {
    FormSection("actions") {
      FormRow.action(
        "message",
        subject.kind == .selfChat ? String(localized: "Open Chat") : String(localized: "Message"),
        icon: FormIcon(systemName: "message"),
        role: .accent
      ) { [weak self] in
        guard let self else { return }
        openChat(peer)
      }
    }
    if subject.kind != .selfChat, let user = userInfo?.user {
      let rows = aboutRows(user: user, isBot: subject.kind == .bot)
      if !rows.isEmpty {
        FormSection("about", rows: rows)
      }
    }
  }

  /// Bio, username, email, phone and local time, each only when shared with you.
  private func aboutRows(user: User, isBot: Bool) -> [FormRow] {
    let fields = PeerInfoPersonFields(user: user)
    var rows: [FormRow] = []
    if isBot {
      if let bio = fields.bio {
        rows.append(fieldRow("bio", label: String(localized: "about"), value: bio, copyTitle: String(localized: "Copy About")))
      }
      return rows
    }
    if let bio = fields.bio {
      rows.append(fieldRow("bio", label: String(localized: "bio"), value: bio, copyTitle: String(localized: "Copy Bio")))
    }
    if let username = fields.username {
      let handle = "@\(username)"
      rows.append(fieldRow(
        "username",
        label: String(localized: "username"),
        value: handle,
        copyTitle: String(localized: "Copy Username"),
        action: { Self.copy(handle, toast: "Copied username") }
      ))
    }
    if let email = fields.email {
      rows.append(fieldRow(
        "email",
        label: String(localized: "email"),
        value: email,
        copyTitle: String(localized: "Copy Email Address"),
        action: {
          guard let url = URL(string: "mailto:\(email)") else { return }
          UIApplication.shared.open(url)
        }
      ))
    }
    if let phone = fields.phone {
      rows.append(fieldRow(
        "phone",
        label: String(localized: "phone"),
        value: phone,
        copyTitle: String(localized: "Copy Phone Number"),
        action: {
          let digits = phone.filter { $0.isNumber || $0 == "+" }
          guard let url = URL(string: "tel:\(digits)") else { return }
          UIApplication.shared.open(url)
        }
      ))
    }
    if let localTime = fields.localTime {
      rows.append(fieldRow("localTime", label: String(localized: "local time"), value: localTime, copyTitle: String(localized: "Copy")))
    }
    return rows
  }

  private func fieldRow(
    _ id: String,
    label: String,
    value: String,
    copyTitle: String,
    action: (@MainActor () -> Void)? = nil
  ) -> FormRow {
    let isAction = action != nil
    return FormRow.custom(
      id,
      reuseIdentifier: ChatInfoFieldCell.reuseIdentifier,
      contentKey: "\(label)|\(value)|\(isAction)",
      onSelect: action
    ) { cell in
      (cell as? ChatInfoFieldCell)?.configure(label: label, value: value, isAction: isAction)
    }
    .menu {
      UIMenu(children: [
        UIAction(title: copyTitle, image: UIImage(systemName: "doc.on.doc")) { _ in
          Self.copy(value, toast: "Copied")
        },
      ])
    }
  }

  // MARK: Thread

  @FormSectionsBuilder
  private func threadSections(subject: PeerInfoSubject) -> [FormSection] {
    let following = isFollowing
    FormSection("actions") {
      FormRow.action(
        "open",
        String(localized: "Open Thread"),
        icon: FormIcon(systemName: "bubble.left.and.bubble.right"),
        role: .accent
      ) { [weak self] in
        guard let self else { return }
        openChat(peer)
      }
      FormRow.toggle(
        "follow",
        String(localized: "Follow"),
        subtitle: following
          ? String(localized: "New messages appear in Open Chats.")
          : String(localized: "Only mentions and replies bring it back."),
        icon: FormIcon(systemName: following ? "eye.fill" : "eye"),
        isOn: following
      ) { [weak self] isOn in
        self?.setFollow(isOn)
      }
    }

    if let parentChatId = subject.parentChatId {
      FormSection("parent") {
        FormRow.navigation(
          "parent",
          ObjectCache.shared.getChat(id: parentChatId)?.humanReadableTitle ?? String(localized: "Parent thread"),
          subtitle: subject.parentMessageId != nil
            ? String(localized: "Started from a message here")
            : String(localized: "Parent thread"),
          icon: FormIcon(systemName: "arrow.turn.up.left")
        ) { [weak self] in
          self?.openParent(subject: subject)
        }
      }
    }

    if let chat = currentChat, chat.spaceId != nil, chat.parentChatId == nil {
      let isPublic = chat.isPublic == true
      let canChange = canChangeVisibility
      FormSection("visibility", header: String(localized: "Visibility"), footer: visibilityFooter(isPublic: isPublic, canChange: canChange)) {
        FormRow.value(
          "visibility",
          isPublic ? String(localized: "Public") : String(localized: "Private"),
          value: nil,
          icon: FormIcon(systemName: isPublic ? "person.2" : "lock")
        )
        if canChange {
          FormRow.action(
            "changeVisibility",
            isPublic ? String(localized: "Make Private…") : String(localized: "Make Public…")
          ) { [weak self] in
            if isPublic { self?.presentMakePrivate() } else { self?.confirmMakePublic() }
          }
        }
      }
    }

    membersSections()
  }

  private func visibilityFooter(isPublic: Bool, canChange: Bool) -> String {
    if isPublic { return String(localized: "Everyone in this space can read and join this thread.") }
    return canChange
      ? String(localized: "Only the people and groups you add can read this thread.")
      : String(localized: "Only the people and groups added can read this thread. The creator or a space admin can change this.")
  }

  @FormSectionsBuilder
  private func membersSections() -> [FormSection] {
    if let participants {
      let roles = memberRoles
      let canRemove = canManageParticipants
      if currentChat?.isPublic == true {
        FormSection("public") {
          FormRow.value(
            "public",
            String(localized: "Everyone in this space can read and join"),
            value: nil,
            icon: FormIcon(systemName: "globe")
          )
        }
      }

      let groups = participants.groupParticipants
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
      if !groups.isEmpty {
        FormSection(
          "groups",
          header: groups.count == 1 ? String(localized: "1 Group") : String(localized: "\(groups.count) Groups")
        ) {
          for group in groups {
            groupRow(group, canRemove: canRemove)
          }
        }
      }

      let people = sortedPeople(participants.participants, roles: roles)
      FormSection(
        "people",
        header: people.count == 1 ? String(localized: "1 Person") : String(localized: "\(people.count) People")
      ) {
        if canAddParticipants {
          FormRow.action(
            "addMembers",
            String(localized: "Add Members"),
            icon: FormIcon(systemName: "person.badge.plus")
          ) { [weak self] in
            self?.presentAddMembers()
          }
        }
        for person in people {
          personRow(person, role: roles[person.user.id], canRemove: canRemove)
        }
      }
    }
  }

  /// You first, then owners, admins, people and bots, each by name.
  private func sortedPeople(_ people: [UserInfo], roles: [Int64: MemberRole]) -> [UserInfo] {
    let currentUserId = currentUserId
    func rank(_ info: UserInfo) -> Int {
      if info.user.id == currentUserId { return 0 }
      switch roles[info.user.id] {
      case .owner: return 1
      case .admin: return 2
      default: return info.user.bot ? 4 : 3
      }
    }
    return people.sorted { lhs, rhs in
      let lhsRank = rank(lhs), rhsRank = rank(rhs)
      if lhsRank != rhsRank { return lhsRank < rhsRank }
      let comparison = lhs.user.displayName.localizedCaseInsensitiveCompare(rhs.user.displayName)
      return comparison == .orderedSame ? lhs.user.id < rhs.user.id : comparison == .orderedAscending
    }
  }

  private func personRow(_ person: UserInfo, role: MemberRole?, canRemove: Bool) -> FormRow {
    let userId = person.user.id
    let isMe = userId == currentUserId
    let removable = canRemove && !isMe
    let detail: String? = person.user.bot
      ? String(localized: "bot")
      : person.user.username.flatMap { $0.isEmpty ? nil : "@\($0)" }
    let key = PersonKey(userInfo: person, isMe: isMe, detail: detail, role: role, removable: removable)
    var row = FormRow.custom(
      "user-\(userId)",
      reuseIdentifier: ChatInfoPersonCell.reuseIdentifier,
      contentKey: key,
      onSelect: { [weak self] in self?.pushInfo(for: .user(id: userId)) }
    ) { cell in
      (cell as? ChatInfoPersonCell)?.configure(
        userInfo: person,
        isMe: isMe,
        detail: detail,
        role: role,
        trailing: .disclosure
      )
    }
    .menu { [weak self] in
      var actions: [UIMenuElement] = []
      if !isMe {
        actions.append(UIAction(title: String(localized: "Message"), image: UIImage(systemName: "message")) { _ in
          self?.openChat(.user(id: userId))
        })
      }
      actions.append(UIAction(title: String(localized: "Show Info"), image: UIImage(systemName: "info.circle")) { _ in
        self?.pushInfo(for: .user(id: userId))
      })
      if removable {
        actions.append(UIMenu(options: .displayInline, children: [
          UIAction(
            title: String(localized: "Remove from Thread"),
            image: UIImage(systemName: "person.badge.minus"),
            attributes: .destructive
          ) { _ in
            self?.confirmRemoveParticipant(person)
          },
        ]))
      }
      return UIMenu(children: actions)
    }
    if removable {
      row = row.deletable(String(localized: "Remove")) { [weak self] in
        self?.confirmRemoveParticipant(person)
      }
    }
    return row
  }

  private func groupRow(_ group: UserGroup, canRemove: Bool) -> FormRow {
    var row = FormRow.value(
      "group-\(group.id)",
      group.name,
      value: nil,
      subtitle: group.memberCount == 1 ? String(localized: "1 person") : String(localized: "\(group.memberCount) people"),
      icon: FormIcon(systemName: "person.3.fill", tint: .white, background: .tintColor)
    )
    if canRemove {
      row = row.deletable(String(localized: "Remove")) { [weak self] in
        self?.confirmRemoveGroup(group)
      }
    }
    return row
  }

  // MARK: Common

  @FormSectionsBuilder
  private func commonSections() -> [FormSection] {
    let selection = notificationSelection
    let globalMode = INUserSettings.current.notification.mode
    let options: [DialogNotificationSettingSelection] = [.global] + DialogNotificationSettingsPresentation.overrideOptions
    FormSection(
      "notifications",
      header: String(localized: "Notifications"),
      footer: selection == .global
        ? DialogNotificationSettingsPresentation.globalDescription
        : DialogNotificationSettingsPresentation.overrideDescription
    ) {
      for option in options {
        FormRow.check(
          "notify-\(option.rawValue)",
          DialogNotificationSettingsPresentation.title(for: option, globalMode: globalMode),
          icon: FormIcon(systemName: DialogNotificationSettingsPresentation.iconName(for: option, globalMode: globalMode)),
          isSelected: option == selection
        ) { [weak self] in
          self?.updateNotificationSelection(option)
        }
      }
    }

    let isArchived = dialog.archived == true
    let nextPinned = nextPinnedState
    let chatId = currentChatId
    FormSection("chat") {
      if let nextPinned {
        FormRow.action(
          "pin",
          nextPinned ? String(localized: "Pin") : String(localized: "Unpin"),
          icon: FormIcon(systemName: nextPinned ? "pin" : "pin.slash"),
          role: .normal
        ) { [weak self] in
          self?.updatePinned(nextPinned)
        }
      }
      FormRow.action(
        "archive",
        isArchived ? String(localized: "Unarchive") : String(localized: "Archive"),
        icon: FormIcon(systemName: isArchived ? "arrow.uturn.backward.circle" : "archivebox"),
        role: .normal
      ) { [weak self] in
        self?.setArchived(!isArchived)
      }
      FormRow.action(
        "copyLink",
        String(localized: "Copy Link"),
        icon: FormIcon(systemName: "link"),
        role: .normal,
        isEnabled: chatId > 0
      ) { [weak self] in
        self?.copyChatLink()
      }
    }

    if let action = destructiveAction {
      FormSection("destructive") {
        FormRow.button("destructive", action.title, role: .destructive) { [weak self] in
          self?.confirmDestructiveAction(action)
        }
      }
    }
  }

  // MARK: Navigation

  /// Leaves chat info for a chat. Over that chat (sheet, or pushed right above it) it just
  /// goes back to it.
  private func openChat(_ target: Peer) {
    CompatHaptics.impact(.light)
    let path = router.selectedTabPath
    if isInSheet {
      dismissSheet()
      router.resetTransientPresentation()
      if path.last?.chatPeer == target { return }
      router.openPrimaryDestination(.chat(peer: target))
      return
    }
    if path.count >= 2, case .some(.chatInfo) = path.last, path[path.count - 2].chatPeer == target {
      router.pop()
      return
    }
    router.resetTransientPresentation()
    router.openPrimaryDestination(.chat(peer: target))
  }

  /// Opens another peer's info on top of this one, without leaving the sheet.
  private func pushInfo(for target: Peer) {
    CompatHaptics.impact(.light)
    guard let item = FullChatViewModel.cachedChatItem(peer: target) else {
      // No local chat yet: the chat itself is the profile until it loads.
      openChat(target)
      return
    }
    if !isInSheet, navigationController is RouterNavigationController {
      router.push(.chatInfo(chatItem: item))
    } else {
      navigationController?.pushViewController(
        ChatInfoViewController(chatItem: item, shell: shell, editing: false),
        animated: true
      )
    }
  }

  private func openParent(subject: PeerInfoSubject) {
    guard let parentChatId = subject.parentChatId else { return }
    let parentPeer = ObjectCache.shared.getChat(id: parentChatId)?.deepLinkPeer ?? .thread(id: parentChatId)
    if let messageId = subject.parentMessageId, router.tracksHistory {
      if isInSheet { dismissSheet() }
      router.resetTransientPresentation()
      router.openPrimaryDestination(.chatMessage(peer: parentPeer, messageID: messageId))
    } else {
      openChat(parentPeer)
    }
  }

  private func dismissSheet() {
    if case .some(.chatInfo) = router.presentedSheet {
      // Router-driven sheet: the shell dismisses it.
      router.dismissSheet()
    } else if let presenter = navigationController?.presentingViewController {
      presenter.dismiss(animated: true)
    } else {
      dismiss(animated: true)
    }
  }

  private func handleChatDeleted(_ notification: Notification) {
    guard let chatId = notification.userInfo?["chatId"] as? Int64, chatId != 0, chatId == currentChatId else { return }
    if isInSheet {
      dismissSheet()
    } else {
      Self.dropRoutesAfterCurrentTurn(router: router, peer: peer)
    }
  }

  /// Removes this chat's info and the chat itself from the top of the selected tab. Runs on
  /// the next turn, after the chat beneath has handled the same deletion (it pops once).
  private static func dropRoutesAfterCurrentTurn(router: Router, peer: Peer) {
    DispatchQueue.main.async {
      let tab = router.selectedTab
      var path = router[tab]
      while let last = path.last {
        if last.chatPeer == peer {
          path.removeLast()
        } else if case let .chatInfo(item) = last, item.peerId == peer {
          path.removeLast()
        } else {
          break
        }
      }
      if path.count != router[tab].count {
        router.setPathFromNavigation(path, for: tab)
      }
    }
  }

  // MARK: Editing

  /// Rename (and emoji) prompt; replaces the SwiftUI in-place editor and emoji picker.
  private func presentRenamePrompt() {
    guard !isSavingInfo, currentChatId != 0, subject.isThread else { return }
    let alert = UIAlertController(title: String(localized: "Edit Thread"), message: nil, preferredStyle: .alert)
    let currentTitle = currentChat?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    alert.addTextField { field in
      field.placeholder = String(localized: "Thread Name")
      field.text = currentTitle
      field.autocapitalizationType = .sentences
      field.clearButtonMode = .whileEditing
      field.returnKeyType = .done
    }
    alert.addTextField { [currentEmoji = currentChat?.emoji] field in
      field.placeholder = String(localized: "Emoji (optional)")
      field.text = currentEmoji
      field.clearButtonMode = .whileEditing
    }
    alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
    let save = UIAlertAction(title: String(localized: "Save"), style: .default) { [weak self, weak alert] _ in
      let title = alert?.textFields?.first?.text ?? ""
      let emoji = alert?.textFields?.last?.text ?? ""
      self?.saveChatInfo(title: title, emojiText: emoji)
    }
    save.isEnabled = !currentTitle.isEmpty
    alert.addAction(save)
    alert.preferredAction = save
    if let titleField = alert.textFields?.first {
      titleField.addAction(UIAction { [weak save, weak titleField] _ in
        save?.isEnabled = !(titleField?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }, for: .editingChanged)
    }
    topmostPresented.present(alert, animated: true)
  }

  private func saveChatInfo(title: String, emojiText: String) {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty, currentChatId != 0 else { return }
    let trimmedEmoji = emojiText.trimmingCharacters(in: .whitespacesAndNewlines)
    // Keep the current icon when the field holds something that isn't an emoji.
    let emoji = Self.firstEmoji(in: trimmedEmoji) ?? (trimmedEmoji.isEmpty ? "" : currentChat?.emoji ?? "")
    let chatId = currentChatId
    isSavingInfo = true
    Task { [weak self] in
      do {
        _ = try await Api.realtime.send(.updateChatInfo(chatID: chatId, title: trimmedTitle, emoji: emoji))
      } catch {
        Log.shared.error("Failed to update chat info", error: error)
        ToastManager.shared.showToast("Couldn’t save thread", type: .error, systemImage: "exclamationmark.triangle")
      }
      self?.isSavingInfo = false
    }
  }

  private static func firstEmoji(in text: String) -> String? {
    for character in text {
      guard let first = character.unicodeScalars.first else { continue }
      if first.properties.isEmojiPresentation || (first.properties.isEmoji && character.unicodeScalars.count > 1) {
        return String(character)
      }
    }
    return nil
  }

  // MARK: Members

  private func presentAddMembers() {
    guard currentChatId != 0, let participants else { return }
    let chatId = currentChatId
    let picker = ChatInfoMemberPickerViewController(
      title: String(localized: "Add Members"),
      spaceMembers: currentChat?.spaceId != nil ? spaceFullMembers : nil,
      mode: .add(excluding: participants.effectiveUserIds, onAdd: { userInfo in
        do {
          try await Api.realtime.send(.addChatParticipant(chatID: chatId, userID: userInfo.user.id))
          return true
        } catch {
          Log.shared.error("Failed to add participant", error: error)
          ToastManager.shared.showToast(
            "Couldn’t add \(userInfo.user.shortDisplayName)",
            type: .error,
            systemImage: "exclamationmark.triangle"
          )
          return false
        }
      })
    )
    presentSheet(picker)
  }

  private func confirmRemoveParticipant(_ person: UserInfo) {
    Task { [weak self] in
      guard let self else { return }
      let name = person.user.shortDisplayName
      let confirmed = await confirm(
        title: String(localized: "Remove from this thread?"),
        message: String(localized: "\(name) will lose access unless a group or the space still gives it."),
        confirmTitle: String(localized: "Remove \(name)"),
        destructive: true,
        style: .actionSheet
      )
      guard confirmed else { return }
      removeParticipant(person)
    }
  }

  private func removeParticipant(_ userInfo: UserInfo) {
    guard currentChatId != 0 else { return }
    let chatId = currentChatId
    let participants = participants
    Task {
      do {
        try await Api.realtime.send(.removeChatParticipant(chatID: chatId, userID: userInfo.user.id))
        await participants?.refetchParticipants()
      } catch {
        Log.shared.error("Failed to remove participant", error: error)
        ToastManager.shared.showToast(
          "Couldn’t remove \(userInfo.user.shortDisplayName)",
          type: .error,
          systemImage: "exclamationmark.triangle"
        )
      }
    }
  }

  private func confirmRemoveGroup(_ group: UserGroup) {
    Task { [weak self] in
      guard let self else { return }
      let confirmed = await confirm(
        title: String(localized: "Remove group access?"),
        message: String(localized: "Members may still have access directly, through the parent thread, or through another group."),
        confirmTitle: String(localized: "Remove \(group.name)"),
        destructive: true,
        style: .actionSheet
      )
      guard confirmed, currentChatId != 0 else { return }
      let chatId = currentChatId
      do {
        try await Api.realtime.send(.removeChatParticipant(chatID: chatId, groupID: group.id))
      } catch {
        Log.shared.error("Failed to remove group participant", error: error)
        ToastManager.shared.showToast("Couldn’t remove \(group.name)", type: .error, systemImage: "exclamationmark.triangle")
      }
    }
  }

  // MARK: Visibility

  private func confirmMakePublic() {
    guard currentChatId != 0 else { return }
    let chatId = currentChatId
    let participants = participants
    Task { [weak self] in
      guard let self else { return }
      let confirmed = await confirm(
        title: String(localized: "Make Thread Public"),
        message: String(localized: "Everyone in this space will be able to read and join it. People without access to public chats will lose access."),
        confirmTitle: String(localized: "Make Public")
      )
      guard confirmed else { return }
      do {
        _ = try await Api.realtime.send(.updateChatVisibility(chatID: chatId, isPublic: true, participantIDs: []))
        await participants?.refetchParticipants()
      } catch {
        Log.shared.error("Failed to make chat public", error: error)
        ToastManager.shared.showToast("Couldn’t make thread public", type: .error, systemImage: "exclamationmark.triangle")
      }
    }
  }

  private func presentMakePrivate() {
    guard currentChatId != 0, let spaceFullMembers else { return }
    let chatId = currentChatId
    let me = currentUserId
    let participants = participants
    let picker = ChatInfoMemberPickerViewController(
      title: String(localized: "Select Participants"),
      spaceMembers: spaceFullMembers,
      mode: .select(
        initial: me.map { [$0] } ?? [],
        locked: me,
        confirmTitle: String(localized: "Make Private"),
        onConfirm: { selection in
        var participantIds = selection
        if let me { participantIds.insert(me) }
        do {
          _ = try await Api.realtime.send(.updateChatVisibility(
            chatID: chatId,
            isPublic: false,
            participantIDs: Array(participantIds)
          ))
          await participants?.refetchParticipants()
          return true
        } catch {
          Log.shared.error("Failed to make chat private", error: error)
          ToastManager.shared.showToast("Couldn’t make thread private", type: .error, systemImage: "exclamationmark.triangle")
          return false
        }
      })
    )
    presentSheet(picker)
  }

  // MARK: Dialog actions

  private func updateNotificationSelection(_ selection: DialogNotificationSettingSelection) {
    guard selection != notificationSelection else { return }
    CompatHaptics.selection()
    pendingNotificationSelection = selection
    notificationGeneration &+= 1
    let generation = notificationGeneration
    setNeedsFormUpdate()
    let peer = peer
    Task(priority: .userInitiated) { [weak self] in
      do {
        _ = try await Api.realtime.send(.updateDialogNotificationSettings(peerId: peer, selection: selection))
      } catch is CancellationError {
      } catch let error as URLError where error.code == .cancelled {
      } catch {
        Log.shared.error("Failed to update dialog notification settings", error: error)
        ToastManager.shared.showToast("Could not update notifications", type: .error, systemImage: "exclamationmark.triangle")
      }
      // The dialog observation carries the saved choice (or the old one after a failure).
      guard let self, notificationGeneration == generation else { return }
      pendingNotificationSelection = nil
      setNeedsFormUpdate()
    }
  }

  private func setFollow(_ follow: Bool) {
    guard follow != isFollowing else { return }
    pendingFollow = follow
    setNeedsFormUpdate()
    let peer = peer
    Task(priority: .userInitiated) { [weak self] in
      do {
        _ = try await Api.realtime.send(.updateDialogFollowMode(peerId: peer, selection: follow ? .following : .unfollowed))
        ToastManager.shared.showToast(
          follow ? "Following" : "Unfollowed",
          description: follow
            ? "New messages will appear in Open Chats."
            : "Only mentions and replies can bring this thread back.",
          type: .success,
          systemImage: follow ? "eye.fill" : "eye.slash.fill"
        )
      } catch is CancellationError {
      } catch {
        Log.shared.error("Failed to update follow state", error: error)
        ToastManager.shared.showToast("Couldn’t update follow", type: .error, systemImage: "exclamationmark.triangle.fill")
      }
      self?.pendingFollow = nil
      self?.setNeedsFormUpdate()
    }
  }

  private func updatePinned(_ pinned: Bool) {
    let peer = peer
    Task(priority: .userInitiated) {
      do {
        _ = try await Api.realtime.send(.updateDialogOrder(peerId: peer, pinned: pinned))
        ToastManager.shared.showToast(pinned ? "Pinned" : "Unpinned", type: .success, systemImage: pinned ? "pin.fill" : "pin.slash")
      } catch is CancellationError {
      } catch {
        Log.shared.error("Failed to update pin state", error: error)
        ToastManager.shared.showToast("Couldn’t update pin", type: .error, systemImage: "exclamationmark.triangle")
      }
    }
  }

  /// Same call as the home list's archive and unarchive.
  private func setArchived(_ archived: Bool, showsSuccessToast: Bool = true) {
    let peer = peer
    let spaceId = currentChat?.spaceId ?? dialog.spaceId
    let shell = shell
    Task { [weak self] in
      do {
        let didPerform = try await shell.homeActions.perform(peer: peer) {
          try await shell.data.updateDialog(
            peerId: peer, archived: archived, spaceId: spaceId, deleteEmptyThreadIfArchiving: false
          )
        }
        guard didPerform, showsSuccessToast else { return }
        if archived {
          ToastManager.shared.showToast(
            "Archived",
            type: .success,
            systemImage: "archivebox.fill",
            action: { [weak self] in self?.setArchived(false, showsSuccessToast: false) },
            actionTitle: "Undo"
          )
        } else {
          ToastManager.shared.showToast("Restored to All Chats", type: .success, systemImage: "arrow.uturn.backward.circle.fill")
        }
      } catch {
        Log.shared.error(archived ? "Failed to archive chat" : "Failed to unarchive chat", error: error)
        ToastManager.shared.showToast(
          archived ? "Could not archive chat" : "Could not restore chat",
          type: .error,
          systemImage: "exclamationmark.triangle.fill"
        )
      }
    }
  }

  private func copyChatLink() {
    guard currentChatId > 0, let url = InlineDeepLink.chat(id: currentChatId).webURL else {
      ToastManager.shared.showToast("Couldn’t copy link", type: .error, systemImage: "exclamationmark.triangle")
      return
    }
    Self.copy(url.absoluteString, toast: "Copied link")
  }

  // MARK: Leave / delete

  private func confirmDestructiveAction(_ action: ChatDestructiveAction) {
    let title = chatTitle
    Task { [weak self] in
      guard let self else { return }
      let confirmed = await confirm(
        title: action.title,
        message: action.confirmationMessage(chatTitle: title),
        confirmTitle: action.shortTitle,
        destructive: true
      )
      guard confirmed else { return }
      performDestructiveAction(action)
    }
  }

  /// Deletes or leaves the thread with the same account fencing as `ChatInfoView`, so an
  /// account switch mid-request never touches the wrong local data.
  private func performDestructiveAction(_ action: ChatDestructiveAction) {
    let peer = peer
    let auth = Auth.shared.handle
    let token: AuthAccountMutationToken
    do {
      token = try auth.beginAccountMutation()
    } catch {
      ToastManager.shared.showToast(action.failureTitle, type: .error, systemImage: "exclamationmark.triangle")
      return
    }
    let writer = AppDatabase.shared.dbWriter
    let router = router
    Task(priority: .userInitiated) { [weak self] in
      do {
        switch action {
        case .delete:
          _ = try await Api.realtime.send(.deleteChat(peerId: peer), expectedAccount: token)
        case .leave:
          guard let chatId = peer.asThreadId() else { return }
          _ = try await Api.realtime.send(
            .removeChatParticipant(chatID: chatId, userID: token.userID),
            expectedAccount: token
          )
          try await Chat.deleteFromLocalDatabase(peerId: peer, databaseWriter: writer, auth: auth, accountToken: token)
        }
        try auth.validateAccountMutation(token)
        ToastManager.shared.showToast(action.successTitle, type: .success, systemImage: action.systemImage)
        if let self, isInSheet { dismissSheet() }
        router.resetTransientPresentation()
        // A deleted chat's routes go with its deletion update; leaving posts none.
        if action == .leave {
          Self.dropRoutesAfterCurrentTurn(router: router, peer: peer)
        }
      } catch {
        Log.shared.error(action.failureTitle, error: error)
        guard (try? auth.validateAccountMutation(token)) != nil else { return }
        ToastManager.shared.showToast(action.failureTitle, type: .error, systemImage: "exclamationmark.triangle")
      }
    }
  }

  // MARK: Helpers

  private static func copy(_ string: String, toast: String) {
    UIPasteboard.general.string = string
    CompatHaptics.notify(.success)
    ToastManager.shared.showToast(toast, type: .success, systemImage: "doc.on.doc")
  }
}

private struct HeaderKey: Hashable {
  var identity: ChatInfoHeaderCell.Identity
  var title: String
  var subtitle: String?
  var isIconTappable: Bool
}

private struct PersonKey: Hashable {
  var userInfo: UserInfo
  var isMe: Bool
  var detail: String?
  var role: MemberRole?
  var removable: Bool
}
