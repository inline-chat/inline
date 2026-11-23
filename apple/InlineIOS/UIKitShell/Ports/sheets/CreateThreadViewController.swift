import Auth
import Combine
import InlineCompatUI
import InlineIOSFoundation
import InlineKit
import InlineUI
import Logger
import RealtimeV2
import UIKit

/// UIKit port of `CreateChatView` (apple/InlineIOS/Features/CreateChat/): title with optional
/// emoji, space (when none is given), Public / Private, and for private threads the participants
/// picked from the space's members. The SwiftUI flow's three steps are one form here. Creates with
/// `RealtimeV2.createThreadLocally` and replaces this screen with the new thread.
@MainActor
final class CreateThreadViewController: FormViewController {
  private unowned let shell: MainShellController
  /// The space this screen was opened for; nil lets the person pick one.
  private let fixedSpaceId: Int64?

  // Field edits re-render (no visible change) so a re-dequeued field cell gets current text.
  private var threadTitle = "" {
    didSet { if threadTitle != oldValue { updateCreateItem(); setNeedsFormUpdate() } }
  }

  private var emoji = "" { didSet { if emoji != oldValue { setNeedsFormUpdate() } } }
  private var spaces: [Space] = [] { didSet { setNeedsFormUpdate() } }
  private var selectedSpaceId: Int64? {
    didSet {
      guard selectedSpaceId != oldValue else { return }
      selectedParticipants = []
      loadMembers()
      updateCreateItem()
      setNeedsFormUpdate()
    }
  }

  private var isPublic = true { didSet { updateCreateItem(); setNeedsFormUpdate() } }
  private var selectedParticipants: Set<Int64> = [] { didSet { updateCreateItem(); setNeedsFormUpdate() } }
  private var participantQuery = "" { didSet { if participantQuery != oldValue { setNeedsFormUpdate() } } }
  private var membersModel: SpaceFullMembersViewModel?
  private var membersCancellable: AnyCancellable?
  private var cancellables: Set<AnyCancellable> = []
  private var isLoading = false { didSet { updateCreateItem(); setNeedsFormUpdate() } }
  private var errorMessage: String? { didSet { setNeedsFormUpdate() } }
  private var didFocus = false

  init(spaceId: Int64?, shell: MainShellController) {
    self.shell = shell
    let validSpaceId = spaceId.flatMap { $0 > 0 ? $0 : nil }
    fixedSpaceId = validSpaceId
    super.init(style: .insetGrouped)
    title = String(localized: "New Thread")
    hidesBottomBarWhenPushed = true
    spaces = shell.spaces.spaces
    selectedSpaceId = validSpaceId ?? shell.spaces.spaces.first?.id
    loadMembers()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func registerCells(in tableView: UITableView) {
    SheetPeerRowCell.register(in: tableView)
    tableView.register(SheetEmojiTitleCell.self, forCellReuseIdentifier: SheetEmojiTitleCell.reuseIdentifier)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    navigationItem.largeTitleDisplayMode = .never
    if navigationController?.viewControllers.first === self {
      navigationItem.leftBarButtonItem = UIBarButtonItem(
        systemItem: .cancel,
        primaryAction: UIAction { [weak self] _ in
          guard let self, !isLoading else { return }
          closeShellSheet(shell)
        }
      )
    }
    shell.spaces.$spaces
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] spaces in
        guard let self else { return }
        self.spaces = spaces
        if fixedSpaceId == nil {
          if let selected = selectedSpaceId, !spaces.contains(where: { $0.id == selected }) {
            selectedSpaceId = spaces.first?.id
          } else if selectedSpaceId == nil {
            selectedSpaceId = spaces.first?.id
          }
        }
      }
      .store(in: &cancellables)
    updateCreateItem()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !didFocus else { return }
    didFocus = true
    if let indexPath = indexPath(forRow: "emoji-title", inSection: "title"),
       let cell = tableView.cellForRow(at: indexPath) as? SheetEmojiTitleCell
    {
      cell.titleField.becomeFirstResponder()
    }
  }

  // MARK: State

  private var resolvedSpaceId: Int64? { fixedSpaceId ?? selectedSpaceId }

  private var selectedSpace: Space? {
    guard let id = resolvedSpaceId else { return nil }
    return spaces.first { $0.id == id }
  }

  private var trimmedTitle: String {
    threadTitle.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canCreate: Bool {
    !trimmedTitle.isEmpty && resolvedSpaceId != nil && (isPublic || !selectedParticipants.isEmpty) && !isLoading
  }

  private func loadMembers() {
    guard let spaceId = resolvedSpaceId else {
      membersModel = nil
      membersCancellable = nil
      return
    }
    let model = SpaceFullMembersViewModel(db: AppDatabase.shared, spaceId: spaceId)
    membersModel = model
    membersCancellable = model.$members
      .dropFirst()
      .sink { [weak self] _ in self?.setNeedsFormUpdate() }
  }

  /// Space members to offer, filtered by the search (bots only when the viewer can reach them,
  /// as `ParticipantSearchViewModel` does).
  private var participantCandidates: [UserInfo] {
    let members = (membersModel?.members ?? []).map(\.userInfo)
    let query = participantQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    return members.filter { userInfo in
      AgentGrantStore.shared.offers(userInfo.user)
        && (query.isEmpty || InviteDirectory.localUserMatches(userInfo, query: query, includeEmail: true))
    }
  }

  private func updateCreateItem() {
    guard isViewLoaded else { return }
    if isLoading {
      let spinner = UIActivityIndicatorView(style: .medium)
      spinner.startAnimating()
      navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
    } else {
      let create = UIBarButtonItem(
        title: String(localized: "Create"),
        primaryAction: UIAction { [weak self] _ in self?.createThread() }
      )
      create.style = .done
      create.isEnabled = canCreate
      navigationItem.rightBarButtonItem = create
    }
  }

  // MARK: Form

  @FormSectionsBuilder
  override func makeSections() -> [FormSection] {
    FormSection("title") {
      FormRow.emojiTitle(
        "emoji-title",
        emoji: emoji,
        title: threadTitle,
        placeholder: String(localized: "Chat title"),
        isEnabled: !isLoading,
        onEmojiChange: { [weak self] value in self?.emoji = value },
        onTitleChange: { [weak self] value in self?.threadTitle = value },
        onSubmit: {}
      )
    }

    if fixedSpaceId == nil {
      FormSection("space") {
        FormRow.navigation(
          "space",
          String(localized: "Space"),
          value: selectedSpace?.displayName ?? String(localized: "Select a space"),
          icon: FormIcon(systemName: "person.3"),
          isEnabled: !isLoading && !spaces.isEmpty
        ) { [weak self] in
          self?.pickSpace()
        }
      }
    }

    FormSection("visibility", header: String(localized: "Visibility")) {
      FormRow.check(
        "public",
        String(localized: "Public"),
        subtitle: "Everyone in \(selectedSpace?.displayName ?? String(localized: "Space"))",
        icon: FormIcon(systemName: "globe"),
        isSelected: isPublic,
        isEnabled: !isLoading
      ) { [weak self] in
        self?.isPublic = true
      }
      FormRow.check(
        "private",
        String(localized: "Private"),
        subtitle: String(localized: "Only selected members"),
        icon: FormIcon(systemName: "lock"),
        isSelected: !isPublic,
        isEnabled: !isLoading
      ) { [weak self] in
        self?.isPublic = false
      }
    }

    if !isPublic {
      let candidates = participantCandidates
      FormSection(
        "participants",
        header: String(localized: "Participants"),
        footer: participantsFooter
      ) {
        FormRow.textField(
          "search",
          placeholder: String(localized: "Search by name or username"),
          text: participantQuery
        ) { [weak self] value in
          self?.participantQuery = value
        }
        if candidates.isEmpty {
          FormRow.note(
            "empty",
            participantQuery.isEmpty ? String(localized: "No members in this space yet") : String(localized: "No members found")
          )
        } else {
          for userInfo in candidates {
            FormRow.peer(
              "user-\(userInfo.id)",
              SheetPeerRowCell.Content(
                identity: .user(userInfo),
                title: userInfo.user.displayName,
                subtitle: userInfo.user.username.map { "@\($0)" },
                selection: selectedParticipants.contains(userInfo.id) ? .selected : .unselected,
                isEnabled: !isLoading
              )
            ) { [weak self] in
              self?.toggleParticipant(userInfo.id)
            }
          }
        }
      }
    }

    if let errorMessage {
      FormSection("error") {
        FormRow.value(
          "error",
          errorMessage,
          value: nil,
          icon: FormIcon(systemName: "exclamationmark.triangle.fill", tint: .systemRed)
        )
      }
    }
  }

  private var participantsFooter: String? {
    let count = selectedParticipants.count
    guard count > 0 else { return String(localized: "Select who can see this thread.") }
    return count == 1 ? String(localized: "1 participant") : "\(count) participants"
  }

  // MARK: Actions

  private func toggleParticipant(_ id: Int64) {
    CompatHaptics.selection()
    if selectedParticipants.contains(id) {
      selectedParticipants.remove(id)
    } else {
      selectedParticipants.insert(id)
    }
  }

  private func pickSpace() {
    view.endEditing(true)
    let options = spaces.map {
      SheetChoiceViewController.Option(id: String($0.id), title: $0.displayName, systemImage: nil)
    }
    let picker = SheetChoiceViewController(
      title: String(localized: "Space"),
      groups: [.init(header: nil, options: options)],
      selectedID: selectedSpaceId.map(String.init)
    ) { [weak self] id in
      self?.selectedSpaceId = Int64(id)
    }
    navigationController?.pushViewController(picker, animated: true)
  }

  private func createThread() {
    guard canCreate, let spaceId = resolvedSpaceId else { return }
    guard let currentUserId = Auth.shared.currentUserId else {
      errorMessage = String(localized: "You're signed out. Please log in again.")
      return
    }
    view.endEditing(true)
    errorMessage = nil
    isLoading = true
    // Public threads: the server requires an empty participants list.
    var participantIds: [Int64] = isPublic ? [] : Array(selectedParticipants)
    if !isPublic, participantIds.isEmpty {
      participantIds = [currentUserId]
    }
    let participants = participantIds
    let chatTitle = trimmedTitle
    let chatEmoji: String? = self.emoji.isEmpty ? nil : self.emoji
    let chatIsPublic = self.isPublic
    Task { [weak self] in
      do {
        let chatId = try await Api.realtime.createThreadLocally(
          title: chatTitle,
          emoji: chatEmoji,
          isPublic: chatIsPublic,
          spaceId: spaceId,
          participants: participants
        )
        guard let self else { return }
        isLoading = false
        openCreatedThread(.thread(id: chatId))
      } catch {
        Log.shared.error("Failed to create chat", error: error)
        guard let self else { return }
        isLoading = false
        errorMessage = error.localizedDescription
      }
    }
  }

  /// Replaces this screen with the thread: in a tab stack the create route is swapped for the chat
  /// (as `router.replaceCurrentPath` / `popToRoot + push` did); in a sheet, the sheet closes first.
  private func openCreatedThread(_ peer: Peer) {
    let router = shell.router
    if navigationController is RouterNavigationController {
      var path = router.selectedTabPath
      if let last = path.last, Self.isCreateRoute(last) {
        path.removeLast()
        router.replaceCurrentPath(with: path + [.chat(peer: peer)])
        return
      }
      shell.open(.chat(peer: peer))
    } else {
      let shell = shell
      closeShellSheet(shell)
      shell.open(.chat(peer: peer))
    }
  }

  private static func isCreateRoute(_ destination: Destination) -> Bool {
    switch destination {
    case .createThread, .createSpaceChat: true
    default: false
    }
  }
}
