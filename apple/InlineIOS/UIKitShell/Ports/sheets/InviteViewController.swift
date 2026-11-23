import InlineCompatUI
import InlineIOSFoundation
import InlineKit
import InlineProtocol
import InlineUI
import Invite
import Logger
import RealtimeV2
import UIKit

/// UIKit port of the iOS flow of InlineUI's `InviteView` (Invite/InviteView.swift, InviteIOSView.swift,
/// SpaceInviteLinkCard.swift), on one screen: search people by name/username (local + public user
/// search) or enter an email/phone, pick several, choose role for a space, Invite, then see the
/// outcome (open chat, share to phone invitees, revoke space invites). Space admins also get the
/// space invite link (create, copy, share, disable); Inline invites get a shareable download link.
///
/// Same models and RPCs as `InviteComposerModel` / `SpaceInviteLinkModel` (iOS 17-gated and internal
/// to the Invite module, so their logic is duplicated here). Contacts suggestions are not ported.
@MainActor
final class InviteViewController: FormViewController, UISearchResultsUpdating {
  private unowned let shell: MainShellController
  private let log = Log.scoped("InviteViewController")
  private static let downloadURL = URL(string: "https://inline.chat/download")!

  private var destination: InviteDestination {
    didSet {
      guard destination != oldValue else { return }
      updateTitle()
      loadInviteLink()
      setNeedsFormUpdate()
    }
  }

  private let fixesDestination: Bool
  private var spaces: [InlineKit.Space] = [] { didSet { updateTitle(); setNeedsFormUpdate() } }

  // Search
  private let searchController = UISearchController(searchResultsController: nil)
  private var query = "" {
    didSet {
      guard query != oldValue else { return }
      runSearch()
      setNeedsFormUpdate()
    }
  }

  private var localUsers: [UserInfo] = [] { didSet { setNeedsFormUpdate() } }
  private var remoteUsers: [UserInfo] = [] { didSet { setNeedsFormUpdate() } }
  private var isSearching = false { didSet { setNeedsFormUpdate() } }
  private var searchTask: Task<Void, Never>?
  private var searchGeneration = 0

  // Invite
  private var selected: [InviteCandidate] = [] { didSet { updateInviteItem(); setNeedsFormUpdate() } }
  private var completed: [InviteOutcome] = [] { didSet { setNeedsFormUpdate() } }
  private var revoking: Set<String> = [] { didSet { setNeedsFormUpdate() } }
  private var isAdminAccess = false { didSet { setNeedsFormUpdate() } }
  private var canAccessPublicChats = true { didSet { setNeedsFormUpdate() } }
  private var isSending = false { didSet { updateInviteItem(); setNeedsFormUpdate() } }

  // Space invite link (admins only)
  private var link = InviteLinkState() { didSet { setNeedsFormUpdate() } }
  private var linkTask: Task<Void, Never>?

  init(destination: InviteDestination, shell: MainShellController) {
    self.shell = shell
    self.destination = destination
    if case .space = destination { fixesDestination = true } else { fixesDestination = false }
    super.init(style: .insetGrouped)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// The sheet to present for `Sheet.addMember(spaceId:)` (`.space(id:)`) and `Sheet.inviteToInline`
  /// (`.inline`).
  static func makeSheet(destination: InviteDestination, shell: MainShellController) -> UIViewController {
    ShellSheetSupport.wrap(InviteViewController(destination: destination, shell: shell), shell: shell)
  }

  deinit {
    searchTask?.cancel()
    linkTask?.cancel()
  }

  override func registerCells(in tableView: UITableView) {
    SheetPeerRowCell.register(in: tableView)
  }

  override func viewDidLoad() {
    spaces = shell.spaces.spaces
    super.viewDidLoad()
    navigationItem.largeTitleDisplayMode = .never
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      systemItem: .cancel,
      primaryAction: UIAction { [weak self] _ in self?.close() }
    )
    searchController.searchResultsUpdater = self
    searchController.obscuresBackgroundDuringPresentation = false
    searchController.hidesNavigationBarDuringPresentation = false
    let bar = searchController.searchBar
    bar.placeholder = String(localized: "Name, username, email, or phone")
    bar.autocapitalizationType = .none
    bar.autocorrectionType = .no
    bar.spellCheckingType = .no
    navigationItem.searchController = searchController
    navigationItem.hidesSearchBarWhenScrolling = false
    definesPresentationContext = true
    updateTitle()
    updateInviteItem()

    Task { [weak self] in
      let spaces = (try? await InviteDirectory.spaces(database: AppDatabase.shared)) ?? []
      guard let self, !spaces.isEmpty else { return }
      self.spaces = spaces
    }
    loadInviteLink()
  }

  func updateSearchResults(for searchController: UISearchController) {
    query = searchController.searchBar.text ?? ""
  }

  // MARK: Titles and bar items

  private var isSpaceInvite: Bool {
    if case .space = destination { return true }
    return false
  }

  private var destinationName: String? {
    guard case let .space(id) = destination else { return nil }
    return spaces.first { $0.id == id }?.displayName
  }

  private func updateTitle() {
    guard isViewLoaded else { return }
    switch destination {
    case .inline: title = String(localized: "Invite to Inline")
    case .space: title = "Invite to \(destinationName ?? String(localized: "a space"))"
    }
  }

  private func updateInviteItem() {
    guard isViewLoaded else { return }
    if isSending {
      let spinner = UIActivityIndicatorView(style: .medium)
      spinner.startAnimating()
      navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
    } else {
      let item = UIBarButtonItem(
        title: String(localized: "Invite"),
        primaryAction: UIAction { [weak self] _ in self?.startInvite() }
      )
      item.style = .done
      item.isEnabled = !selected.isEmpty
      navigationItem.rightBarButtonItem = item
    }
    navigationItem.leftBarButtonItem?.isEnabled = !isSending
    isModalInPresentation = isSending
    navigationController?.isModalInPresentation = isSending
  }

  // MARK: Suggestions (InviteComposerModel)

  private var normalizedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var phoneTarget: InviteCandidate? {
    let value = normalizedQuery
    guard value.range(of: #"^\+?[0-9\s().-]+$"#, options: .regularExpression) != nil else { return nil }
    guard value.filter(\.isNumber).count >= 3 else { return nil }
    return InviteCandidate(phone: value)
  }

  private var emailSuggestion: InviteCandidate? {
    guard normalizedQuery.contains("@") else { return nil }
    return InviteCandidate(email: normalizedQuery)
  }

  private var userTargets: [InviteCandidate] {
    guard !normalizedQuery.isEmpty, phoneTarget == nil else { return [] }
    return InviteDirectory.mergedUsers(local: localUsers, remote: remoteUsers, limit: 20).map(InviteCandidate.init)
  }

  private var emptyResultMessage: String? {
    let hasSuggestions = !userTargets.isEmpty || emailSuggestion != nil || phoneTarget != nil
    guard !normalizedQuery.isEmpty, !hasSuggestions, !isSearching else { return nil }
    if normalizedQuery.count < 2 {
      return String(localized: "Enter at least two username characters, an email address, or a phone number.")
    }
    return String(localized: "No people found. Keep typing an email address or enter a phone number.")
  }

  private func runSearch() {
    searchTask?.cancel()
    searchGeneration &+= 1
    let generation = searchGeneration
    let query = normalizedQuery
    localUsers = []
    remoteUsers = []
    guard !query.isEmpty, phoneTarget == nil else {
      isSearching = false
      return
    }
    let searchesRemotely = InviteDirectory.remoteSearchIsEligible(query: query)
    isSearching = searchesRemotely
    searchTask = Task { [weak self] in
      let local = (try? await InviteDirectory.localUsers(query: query, database: AppDatabase.shared)) ?? []
      guard let self, isCurrentSearch(generation, query: query) else { return }
      localUsers = local
      guard searchesRemotely else {
        isSearching = false
        return
      }
      do {
        try await Task.sleep(nanoseconds: 300_000_000)
        try Task.checkCancellation()
        let remote = try await InviteDirectory.remoteUsers(
          query: query, realtime: Api.realtime, database: AppDatabase.shared
        )
        guard isCurrentSearch(generation, query: query) else { return }
        remoteUsers = remote
      } catch is CancellationError {
        return
      } catch {
        guard isCurrentSearch(generation, query: query) else { return }
        log.error("Invite public-user search failed", error: error)
        remoteUsers = []
      }
      if generation == searchGeneration { isSearching = false }
    }
  }

  private func isCurrentSearch(_ generation: Int, query: String) -> Bool {
    !Task.isCancelled && generation == searchGeneration && normalizedQuery == query
  }

  private func isSelected(_ target: InviteCandidate) -> Bool {
    selected.contains { $0.id == target.id }
  }

  private func toggle(_ target: InviteCandidate) {
    guard target.isActionable, !isSending else { return }
    CompatHaptics.selection()
    if let index = selected.firstIndex(where: { $0.id == target.id }) {
      selected.remove(at: index)
    } else {
      selected.append(target)
    }
  }

  /// Picking a result clears the search so the next person can be typed (as the SwiftUI flow).
  private func selectFromResults(_ target: InviteCandidate) {
    let wasSelected = isSelected(target)
    toggle(target)
    if !wasSelected, isSelected(target) {
      searchController.searchBar.text = ""
      query = ""
    }
  }

  // MARK: Form

  @FormSectionsBuilder
  override func makeSections() -> [FormSection] {
    outcomeSections()

    if !selected.isEmpty {
      FormSection(
        "selected",
        header: String(localized: "Selected"),
        footer: isSpaceInvite
          ? String(localized: "Everyone selected will be invited to this space.")
          : String(localized: "Inline starts a direct chat. Choose a space for a team or community.")
      ) {
        for target in selected {
          FormRow.peer("selected-\(target.id)", candidateContent(target, selection: .selected)) { [weak self] in
            self?.toggle(target)
          }
        }
      }
    }

    resultSections()

    if !fixesDestination {
      FormSection("destination") {
        FormRow.navigation(
          "destination",
          String(localized: "Invite To"),
          value: destinationName ?? "Inline",
          icon: FormIcon(systemName: isSpaceInvite ? "person.3" : "message"),
          isEnabled: !isSending
        ) { [weak self] in
          self?.pickDestination()
        }
      }
    }

    if isSpaceInvite {
      FormSection("access", header: String(localized: "Access")) {
        FormRow.check("member", String(localized: "Member"), isSelected: !isAdminAccess, isEnabled: !isSending) {
          [weak self] in self?.isAdminAccess = false
        }
        FormRow.check("admin", String(localized: "Admin"), isSelected: isAdminAccess, isEnabled: !isSending) {
          [weak self] in self?.isAdminAccess = true
        }
        if !isAdminAccess {
          FormRow.toggle(
            "public-chats",
            String(localized: "Can access all public chats"),
            isOn: canAccessPublicChats,
            isEnabled: !isSending
          ) { [weak self] value in
            self?.canAccessPublicChats = value
          }
        }
      }
    }

    if !selected.isEmpty {
      FormSection("invite") {
        FormRow.button(
          "invite",
          selected.count == 1 ? String(localized: "Invite 1 Person") : "Invite \(selected.count) People",
          isLoading: isSending
        ) { [weak self] in
          self?.startInvite()
        }
      }
    }

    linkSection()
  }

  @FormSectionsBuilder
  private func resultSections() -> [FormSection] {
    if normalizedQuery.isEmpty {
      if selected.isEmpty, completed.isEmpty {
        FormSection("intro") {
          FormRow.note(
            "intro",
            isSpaceInvite
              ? String(localized: "Find an Inline user or invite someone to collaborate in this space.")
              : String(localized: "Invite people to chat. For a team or community, choose a space below.")
          )
        }
      }
    } else {
      let users = userTargets
      if !users.isEmpty {
        FormSection("people", header: String(localized: "People")) {
          for target in users {
            FormRow.peer("result-\(target.id)", candidateContent(target)) { [weak self] in
              self?.selectFromResults(target)
            }
          }
        }
      }
      if let email = emailSuggestion {
        FormSection("email", header: String(localized: "Email")) {
          FormRow.peer("result-\(email.id)", candidateContent(email)) { [weak self] in
            self?.selectFromResults(email)
          }
        }
      }
      if let phone = phoneTarget {
        FormSection("phone", header: String(localized: "Phone")) {
          FormRow.peer("result-\(phone.id)", candidateContent(phone)) { [weak self] in
            self?.selectFromResults(phone)
          }
        }
      }
      if isSearching, users.isEmpty {
        FormSection("status") {
          FormRow("searching", title: String(localized: "Searching…"), accessory: .activity)
        }
      } else if let message = emptyResultMessage {
        FormSection("status") {
          FormRow.note("no-results", message)
        }
      }
    }
  }

  @FormSectionsBuilder
  private func outcomeSections() -> [FormSection] {
    let people = completed.filter { if case .user = $0.target.kind { true } else { false } }
    let emails = completed.filter { if case .email = $0.target.kind { true } else { false } }
    let phones = completed.filter { if case .phone = $0.target.kind { true } else { false } }
    if !people.isEmpty {
      FormSection(
        "outcome-people",
        header: isSpaceInvite ? String(localized: "Added to the Space") : String(localized: "Ready to Chat"),
        footer: isSpaceInvite
          ? String(localized: "These people can open the space now.")
          : String(localized: "These people are already on Inline, so their chats are ready.")
      ) {
        for outcome in people { outcomeRow(outcome) }
      }
    }
    if !emails.isEmpty {
      FormSection(
        "outcome-email",
        header: String(localized: "Email Sent"),
        footer: isSpaceInvite
          ? String(localized: "They can join this space after accepting the email invitation.")
          : String(localized: "They can join Inline from the email and continue in your shared chat.")
      ) {
        for outcome in emails { outcomeRow(outcome) }
      }
    }
    if !phones.isEmpty {
      FormSection(
        "outcome-phone",
        header: String(localized: "Share These Invitations"),
        footer: String(localized: "Send these people an invitation message from your preferred app.")
      ) {
        for outcome in phones { outcomeRow(outcome) }
      }
    }
  }

  private func outcomeRow(_ outcome: InviteOutcome) -> FormRow {
    var content = candidateContent(outcome.target, selection: .none)
    let action: (@MainActor () -> Void)?
    if case .phone = outcome.target.kind {
      content.trailingSymbol = "square.and.arrow.up"
      action = { [weak self] in self?.shareInvitation(for: outcome) }
    } else if case .inline = outcome.destination, case .user = outcome.target.kind {
      content.trailingText = String(localized: "Open Chat")
      action = { [weak self] in self?.openChat(userId: outcome.userID) }
    } else if revoking.contains(outcome.id) {
      content.trailingText = String(localized: "Revoking…")
      action = nil
    } else {
      content.trailingSymbol = "checkmark.circle.fill"
      action = nil
    }
    let row = FormRow.peer("outcome-\(outcome.id)", content, onSelect: action)
    guard case .space = outcome.destination, !revoking.contains(outcome.id) else { return row }
    return row.deletable(String(localized: "Revoke")) { [weak self] in
      self?.revoke(outcome)
    }
  }

  /// Result rows show a selection circle; selected and outcome rows pass their own.
  private func candidateContent(_ target: InviteCandidate) -> SheetPeerRowCell.Content {
    candidateContent(target, selection: isSelected(target) ? .selected : .unselected)
  }

  private func candidateContent(
    _ target: InviteCandidate,
    selection: SheetPeerRowCell.Selection
  ) -> SheetPeerRowCell.Content {
    let identity: SheetPeerRowCell.Identity
    switch target.kind {
    case let .user(userInfo): identity = .user(userInfo)
    case .email: identity = .symbol("envelope")
    case .phone: identity = .symbol("phone")
    }
    return SheetPeerRowCell.Content(
      identity: identity,
      title: target.title,
      subtitle: target.detail,
      selection: selection,
      isEnabled: target.isActionable && !isSending,
      avatarSize: 34
    )
  }

  // MARK: Invite link

  @FormSectionsBuilder
  private func linkSection() -> [FormSection] {
    switch destination {
    case .inline:
      FormSection(
        "share",
        header: String(localized: "Share"),
        footer: String(localized: "Send a link to download Inline from your preferred app.")
      ) {
        FormRow.action(
          "share-download",
          String(localized: "Share Invitation"),
          icon: FormIcon(systemName: "square.and.arrow.up")
        ) { [weak self] in
          self?.presentShareSheet(items: [String(localized: "Join me on Inline so we can chat: https://inline.chat/download")])
        }
        FormRow.action(
          "copy-download",
          String(localized: "Copy Download Link"),
          icon: FormIcon(systemName: "doc.on.doc")
        ) {
          UIPasteboard.general.url = Self.downloadURL
          ToastManager.shared.showToast("Link copied", type: .success, systemImage: "doc.on.doc")
        }
      }
    case .space:
      if link.isAvailable {
        if let url = link.url {
          FormSection(
            "link",
            header: String(localized: "Invite Link"),
            footer: link.expiresAt.map { "Expires \(Self.expiryFormatter.string(from: $0))" }
          ) {
            FormRow.value("link-url", url.absoluteString, value: nil, icon: FormIcon(systemName: "link"))
            FormRow.action(
              "link-copy",
              String(localized: "Copy Link"),
              icon: FormIcon(systemName: "doc.on.doc"),
              isEnabled: !link.isChanging
            ) {
              UIPasteboard.general.string = url.absoluteString
              ToastManager.shared.showToast("Link copied", type: .success, systemImage: "doc.on.doc")
            }
            FormRow.action(
              "link-share",
              String(localized: "Share Link"),
              icon: FormIcon(systemName: "square.and.arrow.up"),
              isEnabled: !link.isChanging
            ) { [weak self] in
              self?.presentShareSheet(items: [url])
            }
            FormRow.action(
              "link-disable",
              String(localized: "Disable Link"),
              icon: FormIcon(systemName: "xmark.circle", tint: .systemRed),
              role: .destructive,
              isLoading: link.isChanging
            ) { [weak self] in
              self?.setLinkEnabled(false)
            }
          }
        } else {
          FormSection(
            "link",
            header: String(localized: "Invite Link"),
            footer: String(localized: "Create one link that people can use to join this space.")
          ) {
            FormRow.action(
              "link-create",
              String(localized: "Create Invite Link"),
              icon: FormIcon(systemName: "link.badge.plus"),
              isLoading: link.isChanging
            ) { [weak self] in
              self?.setLinkEnabled(true)
            }
          }
        }
      }
    }
  }

  private static let expiryFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()

  /// `SpaceInviteLinkModel.load`: only space admins can read the link; anyone else gets no section.
  private func loadInviteLink() {
    linkTask?.cancel()
    link = InviteLinkState()
    guard case let .space(spaceID) = destination else { return }
    linkTask = Task { [weak self] in
      do {
        let result = try await Api.realtime.send(.getSpaceInviteLink(spaceId: spaceID))
        guard let self, !Task.isCancelled, self.destination == .space(id: spaceID),
              case let .getSpaceInviteLink(response) = result
        else { return }
        var state = InviteLinkState()
        state.isAvailable = true
        state.apply(response.hasLink ? response.link : nil)
        link = state
      } catch {
        guard let self, !Task.isCancelled else { return }
        link = InviteLinkState()
      }
    }
  }

  private func setLinkEnabled(_ enabled: Bool) {
    guard case let .space(spaceID) = destination, !link.isChanging else { return }
    link.isChanging = true
    Task { [weak self] in
      do {
        let result = try await Api.realtime.send(.setSpaceInviteLinkEnabled(spaceId: spaceID, enabled: enabled))
        guard let self else { return }
        guard case let .setSpaceInviteLinkEnabled(response) = result else {
          throw SpaceJoinError.invalidResponse
        }
        link.apply(response.hasLink ? response.link : nil)
        link.isChanging = false
      } catch {
        guard let self else { return }
        link.isChanging = false
        presentAlert(
          title: String(localized: "Couldn’t update invite link"),
          message: String(localized: "Couldn’t update the invite link. Please try again.")
        )
      }
    }
  }

  // MARK: Actions

  private func pickDestination() {
    let spaceOptions = spaces.map {
      SheetChoiceViewController.Option(
        id: "space-\($0.id)", title: $0.displayName,
        subtitle: String(localized: "Invite to this space"), systemImage: "person.3"
      )
    }
    var groups: [SheetChoiceViewController.Group] = [
      .init(header: nil, options: [.init(
        id: "inline", title: "Inline",
        subtitle: String(localized: "Start a direct chat"), systemImage: "message"
      )]),
    ]
    if !spaceOptions.isEmpty {
      groups.append(.init(header: String(localized: "Spaces"), options: spaceOptions))
    }
    let selectedID: String = switch destination {
    case .inline: "inline"
    case let .space(id): "space-\(id)"
    }
    let picker = SheetChoiceViewController(
      title: String(localized: "Invite To"), groups: groups, selectedID: selectedID
    ) { [weak self] id in
      guard let self else { return }
      if id == "inline" {
        destination = .inline
      } else if let spaceID = Int64(id.dropFirst("space-".count)) {
        destination = .space(id: spaceID)
      }
    }
    searchController.isActive = false
    navigationController?.pushViewController(picker, animated: true)
  }

  private func startInvite() {
    guard !selected.isEmpty, !isSending else { return }
    searchController.searchBar.resignFirstResponder()
    Task { [weak self] in await self?.invite() }
  }

  /// `InviteComposerModel.invite`: sends each target in turn; successes move to the outcome.
  private func invite() async {
    isSending = true
    let targets = selected
    let destination = destination
    var failures: [String] = []
    completed = []
    for target in targets {
      do {
        let userID = try await send(target, to: destination)
        completed.removeAll { $0.target.id == target.id }
        completed.append(InviteOutcome(target: target, userID: userID, destination: destination))
        selected.removeAll { $0.id == target.id }
      } catch {
        log.error("Invite target failed mechanism=\(target.logMechanism)", error: error)
        failures.append(Self.failureDescription(error))
      }
    }
    isSending = false
    if !completed.isEmpty {
      searchController.searchBar.text = ""
      query = ""
      tableView.setContentOffset(CGPoint(x: 0, y: -tableView.adjustedContentInset.top), animated: true)
    }
    if !failures.isEmpty {
      presentAlert(
        title: String(localized: "Couldn’t complete every invitation"),
        message: failures.count == 1
          ? failures[0]
          : "\(failures.count) invitations failed. Successful invitations are shown above."
      )
    }
  }

  private func send(_ target: InviteCandidate, to destination: InviteDestination) async throws -> Int64 {
    let realtime = Api.realtime
    switch destination {
    case .inline:
      let result: InlineProtocol.RpcResult.OneOf_Result?
      switch target.kind {
      case let .user(info): result = try await realtime.send(.inviteToInline(userID: info.id))
      case .email: result = try await realtime.send(.inviteToInline(email: target.value))
      case .phone: result = try await realtime.send(.inviteToInline(phoneNumber: target.value))
      }
      guard case let .inviteToInline(response) = result else { throw InviteError.invalidResponse }
      return response.user.id

    case let .space(spaceID):
      let access: InviteToSpaceTransaction.Context.AccessRole = isAdminAccess
        ? .admin
        : .member(canAccessPublicChats: canAccessPublicChats)
      let result: InlineProtocol.RpcResult.OneOf_Result?
      switch target.kind {
      case let .user(info):
        result = try await realtime.send(.inviteToSpace(spaceId: spaceID, access: access, userId: info.id))
      case .email:
        result = try await realtime.send(.inviteToSpace(spaceId: spaceID, access: access, email: target.value))
      case .phone:
        result = try await realtime.send(.inviteToSpace(spaceId: spaceID, access: access, phoneNumber: target.value))
      }
      guard case let .inviteToSpace(response) = result else { throw InviteError.invalidResponse }
      return response.user.id
    }
  }

  private func revoke(_ outcome: InviteOutcome) {
    guard case let .space(spaceID) = outcome.destination, !revoking.contains(outcome.id) else { return }
    revoking.insert(outcome.id)
    Task { [weak self] in
      do {
        _ = try await Api.realtime.send(.deleteMember(spaceId: spaceID, userId: outcome.userID))
        guard let self else { return }
        revoking.remove(outcome.id)
        completed.removeAll { $0.id == outcome.id }
      } catch {
        guard let self else { return }
        log.error("Invite revoke failed destination=space", error: error)
        revoking.remove(outcome.id)
        presentAlert(
          title: String(localized: "Couldn’t complete every invitation"),
          message: String(localized: "The invitation could not be revoked.")
        )
      }
    }
  }

  private func shareInvitation(for outcome: InviteOutcome) {
    let message: String = switch outcome.destination {
    case .inline:
      "Join me on Inline so we can chat: https://inline.chat/download"
    case let .space(id):
      "Join me on Inline in \(spaces.first { $0.id == id }?.displayName ?? "our space"): https://inline.chat/download"
    }
    presentShareSheet(items: [message])
  }

  private func openChat(userId: Int64) {
    let shell = shell
    searchController.isActive = false
    closeShellSheet(shell)
    shell.open(.chat(peer: .user(id: userId)))
  }

  private func close() {
    guard !isSending else { return }
    searchController.isActive = false
    closeShellSheet(shell)
  }

  private static func failureDescription(_ error: any Error) -> String {
    guard let realtimeError = error as? RealtimeDirectRpcError else {
      return error.localizedDescription
    }
    switch realtimeError {
    case let .rpcError(errorCode, _, _):
      switch errorCode {
      case .userIDInvalid:
        return "This person can’t be invited. They may be unavailable, or this may be your own email or phone number."
      case .userAlreadyMember:
        return "This person is already a member of the space."
      case .emailInvalid:
        return "Enter a valid email address."
      case .phoneNumberInvalid:
        return "Enter a valid phone number."
      case .spaceAdminRequired:
        return "A space admin must send this invitation."
      case .rateLimit:
        return "You’ve sent several invitations. Wait a moment and try again."
      default:
        return realtimeError.localizedDescription
      }
    case .notAuthorized, .notConnected, .timeout, .commitOutcomeUnknown, .capacityExceeded, .unknown:
      return realtimeError.localizedDescription
    }
  }
}

// MARK: - Models (ported from InviteView.swift, where they are internal and iOS 17-gated)

private enum InviteError: Error { case invalidResponse }

/// `InviteTarget`: a person to invite, by Inline user, email or phone.
private struct InviteCandidate: Hashable {
  enum Kind: Hashable {
    case user(UserInfo)
    case email
    case phone
  }

  let id: String
  let kind: Kind
  let title: String
  let detail: String?
  let value: String
  let isActionable: Bool

  init(userInfo: UserInfo) {
    id = "user:\(userInfo.id)"
    kind = .user(userInfo)
    title = userInfo.user.displayName
    detail = userInfo.user.username.map { "@\($0)" }
    value = String(userInfo.id)
    isActionable = true
  }

  init(email: String) {
    let value = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let isActionable = value.range(
      of: #"^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,64}$"#,
      options: .regularExpression
    ) != nil
    id = "email:\(value)"
    kind = .email
    title = value
    detail = isActionable ? nil : "Complete the email address"
    self.value = value
    self.isActionable = isActionable
  }

  init(phone: String) {
    let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
    let digits = phone.filter(\.isNumber)
    let isActionable = (8 ... 15).contains(digits.count)
    let value = isActionable ? "+\(digits)" : trimmed
    id = "phone:\(value)"
    kind = .phone
    title = value
    detail = isActionable ? nil : "Enter 8–15 digits"
    self.value = value
    self.isActionable = isActionable
  }

  var logMechanism: String {
    switch kind {
    case .user: "user"
    case .email: "email"
    case .phone: "phone"
    }
  }
}

/// `InviteCompletion`.
private struct InviteOutcome: Hashable {
  let target: InviteCandidate
  let userID: Int64
  let destination: InviteDestination
  var id: String { target.id }
}

/// `SpaceInviteLinkModel` state.
private struct InviteLinkState {
  var isAvailable = false
  var isChanging = false
  var url: URL?
  var expiresAt: Date?

  mutating func apply(_ value: InlineProtocol.SpaceInviteLink?) {
    url = value.flatMap { URL(string: $0.url) }
    expiresAt = value.flatMap { $0.hasExpiresAt ? Date(timeIntervalSince1970: TimeInterval($0.expiresAt)) : nil }
  }
}
