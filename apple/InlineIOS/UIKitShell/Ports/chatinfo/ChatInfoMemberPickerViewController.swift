import Auth
import Combine
import InlineCompatUI
import InlineIOSFoundation
import InlineKit
import InlineUI
import Logger
import UIKit

/// Searchable people picker for chat info: adds one person to a thread, or picks who keeps
/// access when a thread goes private. UIKit counterpart of `SearchParticipantsView` and
/// `ChatVisibilityParticipantsSheet` (groups are not offered here).
///
/// With a space, it filters the space's members locally; without one (Home threads), it searches
/// the directory like the SwiftUI sheet: local users first, then the server.
@MainActor
final class ChatInfoMemberPickerViewController: FormViewController, UISearchResultsUpdating {
  enum Mode {
    /// Tap a person to add them; the sheet closes when `onAdd` returns true.
    case add(excluding: Set<Int64>, onAdd: @MainActor (UserInfo) async -> Bool)
    /// Toggle people, then confirm. `locked` stays selected (the viewer).
    case select(
      initial: Set<Int64>,
      locked: Int64?,
      confirmTitle: String,
      onConfirm: @MainActor (Set<Int64>) async -> Bool
    )
  }

  private let mode: Mode
  private let spaceMembers: SpaceFullMembersViewModel?
  private let searchController = UISearchController(searchResultsController: nil)
  private var cancellables: Set<AnyCancellable> = []
  private var query = ""
  private var selected: Set<Int64>
  private var busyUserID: Int64?
  private var isConfirming = false

  // Directory search (no space).
  private var directoryResults: [UserInfo] = []
  private var isSearchingDirectory = false
  private var searchTask: Task<Void, Never>?
  private var searchGeneration: UInt64 = 0

  init(title: String, spaceMembers: SpaceFullMembersViewModel?, mode: Mode) {
    self.mode = mode
    self.spaceMembers = spaceMembers
    if case let .select(initial, locked, _, _) = mode {
      selected = initial.union(locked.map { [$0] } ?? [])
    } else {
      selected = []
    }
    super.init(style: .insetGrouped)
    self.title = title
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit {
    searchTask?.cancel()
  }

  override func registerCells(in tableView: UITableView) {
    tableView.register(ChatInfoPersonCell.self, forCellReuseIdentifier: ChatInfoPersonCell.reuseIdentifier)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    navigationItem.largeTitleDisplayMode = .never
    searchController.obscuresBackgroundDuringPresentation = false
    searchController.searchResultsUpdater = self
    searchController.searchBar.placeholder = spaceMembers == nil
      ? String(localized: "Search people")
      : String(localized: "Search members")
    searchController.searchBar.autocapitalizationType = .none
    searchController.searchBar.autocorrectionType = .no
    navigationItem.searchController = searchController
    navigationItem.hidesSearchBarWhenScrolling = false
    definesPresentationContext = true
    updateConfirmButton()

    spaceMembers?.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.setNeedsFormUpdate() }
      .store(in: &cancellables)
    if let spaceMembers {
      Task { await spaceMembers.refetchMembers() }
    }
  }

  // MARK: UISearchResultsUpdating

  func updateSearchResults(for searchController: UISearchController) {
    let text = searchController.searchBar.text ?? ""
    guard text != query else { return }
    query = text
    if spaceMembers == nil, case .add = mode {
      searchDirectory(text)
    }
    setNeedsFormUpdate()
  }

  // MARK: Sections

  @FormSectionsBuilder
  override func makeSections() -> [FormSection] {
    switch mode {
    case let .add(excluding, _):
      addSections(excluding: excluding)
    case let .select(_, locked, _, _):
      selectSections(locked: locked)
    }
  }

  @FormSectionsBuilder
  private func addSections(excluding: Set<Int64>) -> [FormSection] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if let spaceMembers {
      // Same filter as the SwiftUI sheet; an empty query lists everyone not in the thread yet.
      let candidates = spaceMembers.filteredMembers
        .map(\.userInfo)
        .filter {
          !excluding.contains($0.user.id) && AgentGrantStore.shared.offers($0.user) &&
            InviteDirectory.localUserMatches($0, query: trimmed, includeEmail: true)
        }
        .sorted { $0.user.displayName.localizedCaseInsensitiveCompare($1.user.displayName) == .orderedAscending }
      if candidates.isEmpty {
        FormSection("empty") {
          FormRow.note(
            "empty",
            spaceMembers.isLoading
              ? String(localized: "Loading members…")
              : trimmed.isEmpty
                ? String(localized: "Everyone in this space is already here.")
                : String(localized: "No members found.")
          )
        }
      } else {
        FormSection("people") {
          for userInfo in candidates {
            addRow(userInfo)
          }
        }
      }
    } else {
      if trimmed.isEmpty {
        FormSection("hint") {
          FormRow.note("hint", String(localized: "Search people by name or username."))
        }
      } else if directoryResults.isEmpty {
        FormSection("empty") {
          if isSearchingDirectory {
            FormRow("searching", title: String(localized: "Searching…"), accessory: .activity)
          } else {
            FormRow.note("empty", String(localized: "No people found."))
          }
        }
      } else {
        FormSection("people") {
          for userInfo in directoryResults {
            addRow(userInfo)
          }
          if isSearchingDirectory {
            FormRow("searching", title: String(localized: "Searching…"), accessory: .activity)
          }
        }
      }
    }
  }

  @FormSectionsBuilder
  private func selectSections(locked: Int64?) -> [FormSection] {
    let members = filteredSpaceMembers
    FormSection(
      "people",
      footer: String(localized: "Only selected participants can access this private chat.")
    ) {
      if members.isEmpty {
        FormRow.note(
          "empty",
          spaceMembers?.isLoading == true ? String(localized: "Loading members…") : String(localized: "No members found.")
        )
      }
      for member in members {
        selectRow(member.userInfo, locked: locked)
      }
    }
    if let error = spaceMembers?.errorMessage {
      FormSection("error") {
        FormRow.note("error", error)
      }
    }
  }

  /// Same matching as `ChatVisibilityParticipantsSheet`.
  private var filteredSpaceMembers: [FullMemberItem] {
    let all = spaceMembers?.filteredMembers ?? []
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return all }
    return all.filter { member in
      let user = member.userInfo.user
      return [user.displayName, user.firstName ?? "", user.lastName ?? "", user.username ?? "", user.email ?? ""]
        .map { $0.lowercased() }
        .contains { $0.contains(needle) }
    }
  }

  private func addRow(_ userInfo: UserInfo) -> FormRow {
    let isBusy = busyUserID == userInfo.user.id
    let isEnabled = busyUserID == nil
    let detail = Self.detail(for: userInfo)
    return FormRow.custom(
      "user-\(userInfo.user.id)",
      reuseIdentifier: ChatInfoPersonCell.reuseIdentifier,
      contentKey: PickerRowKey(userInfo: userInfo, detail: detail, trailing: isBusy ? .activity : .none, isEnabled: isEnabled),
      isEnabled: isEnabled,
      onSelect: { [weak self] in self?.addPerson(userInfo) }
    ) { cell in
      (cell as? ChatInfoPersonCell)?.configure(
        userInfo: userInfo,
        isMe: false,
        detail: detail,
        role: nil,
        trailing: isBusy ? .activity : .none,
        isEnabled: isEnabled
      )
    }
  }

  private func selectRow(_ userInfo: UserInfo, locked: Int64?) -> FormRow {
    let userId = userInfo.user.id
    let isLocked = userId == locked
    let isSelected = isLocked || selected.contains(userId)
    let detail = Self.detail(for: userInfo)
    let isEnabled = !isLocked && !isConfirming
    return FormRow.custom(
      "user-\(userId)",
      reuseIdentifier: ChatInfoPersonCell.reuseIdentifier,
      contentKey: PickerRowKey(userInfo: userInfo, detail: detail, trailing: .selection(isSelected), isEnabled: isEnabled),
      isEnabled: isEnabled,
      onSelect: { [weak self] in self?.toggle(userId) }
    ) { cell in
      (cell as? ChatInfoPersonCell)?.configure(
        userInfo: userInfo,
        isMe: isLocked,
        detail: detail,
        role: nil,
        trailing: .selection(isSelected),
        isEnabled: !isLocked
      )
    }
  }

  private static func detail(for userInfo: UserInfo) -> String? {
    if userInfo.user.bot { return String(localized: "bot") }
    guard let username = userInfo.user.username, !username.isEmpty else { return nil }
    return "@\(username)"
  }

  // MARK: Actions

  private func addPerson(_ userInfo: UserInfo) {
    guard case let .add(_, onAdd) = mode, busyUserID == nil else { return }
    CompatHaptics.impact(.light)
    busyUserID = userInfo.user.id
    setNeedsFormUpdate()
    Task { [weak self] in
      let added = await onAdd(userInfo)
      guard let self else { return }
      busyUserID = nil
      if added {
        close()
      } else {
        setNeedsFormUpdate()
      }
    }
  }

  private func toggle(_ userId: Int64) {
    CompatHaptics.selection()
    if selected.contains(userId) {
      selected.remove(userId)
    } else {
      selected.insert(userId)
    }
    updateConfirmButton()
    setNeedsFormUpdate()
  }

  private func updateConfirmButton() {
    guard case let .select(_, _, confirmTitle, _) = mode else { return }
    if isConfirming {
      let spinner = UIActivityIndicatorView(style: .medium)
      spinner.startAnimating()
      navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
      return
    }
    let item = UIBarButtonItem(
      title: confirmTitle,
      primaryAction: UIAction { [weak self] _ in self?.confirmSelection() }
    )
    item.style = .done
    item.isEnabled = !selected.isEmpty
    navigationItem.rightBarButtonItem = item
  }

  private func confirmSelection() {
    guard case let .select(_, _, _, onConfirm) = mode, !isConfirming else { return }
    isConfirming = true
    updateConfirmButton()
    setNeedsFormUpdate()
    let selection = selected
    Task { [weak self] in
      let done = await onConfirm(selection)
      guard let self else { return }
      isConfirming = false
      if done {
        close()
      } else {
        updateConfirmButton()
        setNeedsFormUpdate()
      }
    }
  }

  private func close() {
    if let presenter = navigationController?.presentingViewController {
      presenter.dismiss(animated: true)
    } else {
      dismiss(animated: true)
    }
  }

  // MARK: Directory search

  /// Port of `ChatInfoView.searchUsers` for chats without a space.
  private func searchDirectory(_ rawQuery: String) {
    guard case let .add(excluding, _) = mode else { return }
    searchTask?.cancel()
    searchTask = nil
    searchGeneration &+= 1
    let generation = searchGeneration
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      directoryResults = []
      isSearchingDirectory = false
      return
    }
    let searchesRemotely = InviteDirectory.remoteSearchIsEligible(query: query)
    isSearchingDirectory = true
    searchTask = Task { [weak self] in
      // Debounce typing, as the SwiftUI sheet's 0.3 s debouncer does.
      try? await Task.sleep(nanoseconds: 300_000_000)
      guard !Task.isCancelled else { return }
      do {
        // A locally known bot is offered only to someone who can reach it; the server applies
        // the same rule to what it returns.
        let localUsers = try await InviteDirectory.localUsers(query: query, database: AppDatabase.shared)
        let local = InviteDirectory.mergedUsers(
          local: localUsers,
          remote: [],
          excluding: excluding
        ).filter { AgentGrantStore.shared.offers($0.user) }
        try Task.checkCancellation()
        guard let self, generation == searchGeneration else { return }
        directoryResults = local
        guard searchesRemotely else {
          isSearchingDirectory = false
          setNeedsFormUpdate()
          return
        }
        setNeedsFormUpdate()
        let remote = try await InviteDirectory.remoteUsers(
          query: query,
          realtime: Api.realtime,
          database: AppDatabase.shared
        )
        try Task.checkCancellation()
        guard generation == searchGeneration else { return }
        directoryResults = InviteDirectory.mergedUsers(local: local, remote: remote, excluding: excluding)
        isSearchingDirectory = false
        setNeedsFormUpdate()
      } catch is CancellationError {
        return
      } catch {
        Log.shared.error("Error searching users", error: error)
        guard let self, generation == searchGeneration else { return }
        isSearchingDirectory = false
        setNeedsFormUpdate()
      }
    }
  }
}

private struct PickerRowKey: Hashable {
  var userInfo: UserInfo
  var detail: String?
  var trailing: ChatInfoPersonCell.Trailing
  var isEnabled: Bool
}
