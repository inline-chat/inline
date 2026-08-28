import Contacts
import Foundation
import InlineKit
import InlineProtocol
import InlineUI
import Logger
import Observation
import RealtimeV2
import SwiftUI

public enum InviteDestination: Hashable, Sendable {
  case inline
  case space(id: Int64)

  fileprivate var isSpace: Bool {
    if case .space = self { return true }
    return false
  }
}

public enum InviteFlowStage: Hashable, Sendable {
  case selection
  case review
  case outcome
}

@MainActor
public final class InviteFlowSession: Identifiable {
  public let id: UUID
  let model: InviteComposerModel

  public init(id: UUID = UUID(), destination: InviteDestination) {
    self.id = id
    model = InviteComposerModel(
      destination: destination,
      fixesDestination: destination.isSpace
    )
  }
}

public struct InviteView: View {
  @Environment(\.appDatabase) private var database
  @Environment(\.realtimeV2) private var realtime
  @State private var session: InviteFlowSession

  private let onManageMembers: ((Int64) -> Void)?
  private let onOpenChat: ((InlineKit.Peer) -> Void)?
  private let macStage: InviteFlowStage?
  private let onContinue: (() -> Void)?
  private let onShowOutcome: (() -> Void)?
  private let onInviteMore: (() -> Void)?

  public init(
    destination: InviteDestination,
    onManageMembers: ((Int64) -> Void)? = nil,
    onOpenChat: ((InlineKit.Peer) -> Void)? = nil,
    onCreateSpace: (() -> Void)? = nil
  ) {
    self.onManageMembers = onManageMembers
    self.onOpenChat = onOpenChat
    macStage = nil
    onContinue = nil
    onShowOutcome = nil
    onInviteMore = nil
    _session = State(initialValue: InviteFlowSession(destination: destination))
  }

  public init(
    session: InviteFlowSession,
    stage: InviteFlowStage,
    onContinue: (() -> Void)? = nil,
    onShowOutcome: (() -> Void)? = nil,
    onInviteMore: (() -> Void)? = nil,
    onManageMembers: ((Int64) -> Void)? = nil,
    onOpenChat: ((InlineKit.Peer) -> Void)? = nil
  ) {
    self.onManageMembers = onManageMembers
    self.onOpenChat = onOpenChat
    macStage = stage
    self.onContinue = onContinue
    self.onShowOutcome = onShowOutcome
    self.onInviteMore = onInviteMore
    _session = State(initialValue: session)
  }

  public var body: some View {
    @Bindable var model = session.model
    Group {
      #if os(macOS)
      InviteMacView(
        model: model,
        stage: macStage,
        onContinue: onContinue,
        onShowOutcome: onShowOutcome,
        onInviteMore: onInviteMore,
        onManageMembers: onManageMembers,
        onOpenChat: onOpenChat
      )
      #else
      InviteIOSView(model: model, onOpenChat: onOpenChat)
      #endif
    }
    .task {
      await model.loadContext(database: database)
    }
    .task(id: model.query) {
      await model.search(database: database, realtime: realtime)
    }
    .sheet(isPresented: $model.showsContactsExplanation) {
      InviteContactsPermissionView(
        isLoading: model.contactsState == .loading,
        onAllow: { Task { await model.loadContacts(requestPermission: true) } },
        onCancel: { model.showsContactsExplanation = false }
      )
    }
    .alert("Couldn’t complete every invitation", isPresented: $model.showsError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(model.errorMessage ?? "Please try again.")
    }
  }
}

@MainActor @Observable
final class InviteComposerModel {
  enum AccessLevel: String, CaseIterable, Identifiable {
    case member
    case admin
    var id: Self { self }
    var title: LocalizedStringResource { self == .member ? "Member" : "Admin" }
  }

  enum ContactsState: Equatable {
    case idle
    case loading
    case loaded
    case denied
  }

  var destination: InviteDestination
  let fixesDestination: Bool
  var spaces: [InlineKit.Space] = []
  var query = "" {
    didSet {
      if query != oldValue {
        localUsers = []
        remoteUsers = []
        isSearching = false
      }
      refreshContactTargets()
    }
  }
  var localUsers: [UserInfo] = []
  var remoteUsers: [UserInfo] = []
  private var contacts: [InviteContact] = []
  private(set) var contactTargets: [InviteTarget] = []
  private static let visibleContactLimit = 5
  private var showsAllContacts = false
  private var searchGeneration = 0
  var selected: [InviteTarget] = []
  var completed: [InviteCompletion] = []
  var accessLevel: AccessLevel = .member
  var canAccessPublicChats = true
  var isSearching = false
  var isSending = false
  var showsContactsExplanation = false
  var contactsState: ContactsState = .idle
  var showsError = false
  var errorMessage: String?
  var showsOutcome = false

  init(destination: InviteDestination, fixesDestination: Bool = false) {
    self.destination = destination
    self.fixesDestination = fixesDestination
  }

  var title: String {
    switch destination {
    case .inline:
      "Invite to Inline"
    case .space:
      "Invite to \(destinationName ?? "a space")"
    }
  }

  var subtitle: String {
    switch destination {
    case .inline:
      "Invite people to chat. For a team or community, choose or create a space below."
    case .space:
      "Find an Inline user or invite someone to collaborate in this space."
    }
  }

  var isSpaceInvite: Bool {
    if case .space = destination { return true }
    return false
  }

  var destinationName: String? {
    guard case let .space(id) = destination else { return nil }
    return spaces.first { $0.id == id }?.displayName
  }

  var normalizedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var userTargets: [InviteTarget] {
    guard !normalizedQuery.isEmpty, phoneTarget == nil else { return [] }
    return InviteDirectory.mergedUsers(local: localUsers, remote: remoteUsers, limit: 20)
      .map(InviteTarget.init)
  }

  var emailSuggestion: InviteTarget? {
    guard normalizedQuery.contains("@") else { return nil }
    return InviteTarget(email: normalizedQuery)
  }

  var phoneTarget: InviteTarget? {
    let value = normalizedQuery
    guard value.range(of: #"^\+?[0-9\s().-]+$"#, options: .regularExpression) != nil else { return nil }
    let digits = value.filter(\.isNumber)
    guard digits.count >= 3 else { return nil }
    return InviteTarget(phone: value)
  }

  var hasSuggestions: Bool {
    !userTargets.isEmpty || !contactTargets.isEmpty || emailSuggestion != nil || phoneTarget != nil
  }

  var emptyResultMessage: LocalizedStringResource? {
    guard !normalizedQuery.isEmpty, !hasSuggestions, !isSearching else { return nil }
    if normalizedQuery.count < 2 {
      return "Enter at least two username characters, an email address, or a phone number."
    }
    return "No people found. Keep typing an email address or enter a phone number."
  }

  var peopleCompletions: [InviteCompletion] {
    completed.filter { if case .user = $0.target.kind { true } else { false } }
  }

  var emailCompletions: [InviteCompletion] {
    completed.filter { if case .email = $0.target.kind { true } else { false } }
  }

  var phoneCompletions: [InviteCompletion] {
    completed.filter { if case .phone = $0.target.kind { true } else { false } }
  }

  func loadContext(database: AppDatabase) async {
    spaces = (try? await InviteDirectory.spaces(database: database)) ?? []
    await loadContactsIfAuthorized()
  }

  func search(database: AppDatabase, realtime: RealtimeV2) async {
    searchGeneration &+= 1
    let generation = searchGeneration
    let query = normalizedQuery
    let shouldSearchRemotely = InviteDirectory.remoteSearchIsEligible(query: query)
    guard !query.isEmpty, phoneTarget == nil else {
      localUsers = []
      remoteUsers = []
      isSearching = false
      return
    }

    isSearching = shouldSearchRemotely
    localUsers = []
    remoteUsers = []
    let localResults = (try? await InviteDirectory.localUsers(query: query, database: database)) ?? []
    guard searchIsCurrent(generation, query: query) else { return }
    localUsers = localResults

    guard shouldSearchRemotely else {
      isSearching = false
      return
    }

    do {
      try await Task.sleep(for: .milliseconds(300))
      try Task.checkCancellation()
      let remoteResults = try await InviteDirectory.remoteUsers(
        query: query,
        realtime: realtime,
        database: database
      )
      guard searchIsCurrent(generation, query: query) else { return }
      remoteUsers = remoteResults
    } catch is CancellationError {
      return
    } catch {
      guard searchIsCurrent(generation, query: query) else { return }
      Log.shared.error("Invite public-user search failed", error: error)
      remoteUsers = []
    }
    if generation == searchGeneration {
      isSearching = false
    }
  }

  func toggle(_ target: InviteTarget) {
    guard target.isActionable else { return }
    if let index = selected.firstIndex(where: { $0.id == target.id }) {
      selected.remove(at: index)
    } else {
      selected.append(target)
    }
  }

  func selectFromResults(_ target: InviteTarget) {
    let wasSelected = isSelected(target)
    toggle(target)
    if !wasSelected, isSelected(target) {
      query = ""
    }
  }

  func isSelected(_ target: InviteTarget) -> Bool {
    selected.contains { $0.id == target.id }
  }

  func showContacts() {
    let status = CNContactStore.authorizationStatus(for: .contacts)
    if inviteContactsAuthorized(status) {
      showsAllContacts = true
      refreshContactTargets()
      Task { await loadContacts(requestPermission: false) }
      return
    }
    switch status {
    case .notDetermined:
      showsContactsExplanation = true
    case .denied, .restricted:
      contactsState = .denied
      errorMessage = "Contacts access is unavailable. You can still invite by username, email, or phone."
      showsError = true
    case .authorized:
      break
    #if os(iOS)
    case .limited:
      break
    #endif
    @unknown default:
      showsContactsExplanation = true
    }
  }

  func loadContactsIfAuthorized() async {
    if inviteContactsAuthorized(CNContactStore.authorizationStatus(for: .contacts)) {
      await loadContacts(requestPermission: false)
    }
  }

  func loadContacts(requestPermission: Bool) async {
    contactsState = .loading
    let result = await InviteContactLoader.shared.load(requestPermission: requestPermission)
    switch result {
    case let .success(contacts):
      self.contacts = contacts
      if requestPermission {
        showsAllContacts = true
      }
      refreshContactTargets()
      contactsState = .loaded
      showsContactsExplanation = false
    case let .failure(error):
      Log.shared.error("Invite Contacts load failed", error: error)
      contactsState = .denied
      showsContactsExplanation = false
      errorMessage = "Contacts access is unavailable. You can still invite by username, email, or phone."
      showsError = true
    }
  }

  @discardableResult
  func invite(realtime: RealtimeV2) async -> Bool {
    guard !selected.isEmpty, !isSending else { return false }
    isSending = true
    let targets = selected
    var failures: [(title: String, message: String)] = []
    completed = []

    for target in targets {
      do {
        let userID = try await send(target, realtime: realtime)
        completed.removeAll { $0.target.id == target.id }
        completed.append(InviteCompletion(target: target, userID: userID, destination: destination))
        selected.removeAll { $0.id == target.id }
      } catch {
        Log.shared.error(
          "Invite target failed mechanism=\(target.logMechanism) destination=\(destination.logKind)",
          error: error
        )
        failures.append((target.title, inviteFailureDescription(error)))
      }
    }

    isSending = false
    let hasSuccesses = !completed.isEmpty
    if hasSuccesses {
      query = ""
      showsOutcome = true
    }
    if !failures.isEmpty {
      errorMessage = failures.count == 1
        ? failures[0].message
        : "\(failures.count) invitations failed. Successful invitations are shown below."
      showsError = true
    }
    return hasSuccesses
  }

  func revoke(_ completion: InviteCompletion, realtime: RealtimeV2) async {
    guard case let .space(spaceID) = completion.destination else { return }
    do {
      _ = try await realtime.send(.deleteMember(spaceId: spaceID, userId: completion.userID))
      completed.removeAll { $0.id == completion.id }
    } catch {
      Log.shared.error("Invite revoke failed destination=space", error: error)
      errorMessage = "The invitation could not be revoked."
      showsError = true
    }
  }

  func returnToInvite() {
    showsOutcome = false
    completed = []
    showsAllContacts = false
    refreshContactTargets()
  }

  func name(for destination: InviteDestination) -> String? {
    guard case let .space(id) = destination else { return nil }
    return spaces.first { $0.id == id }?.displayName
  }

  private func refreshContactTargets() {
    let query = normalizedQuery
    guard !query.isEmpty || showsAllContacts else {
      contactTargets = []
      return
    }
    let matches = query.isEmpty ? contacts : contacts.filter { $0.matches(query) }
    contactTargets = Array(matches.prefix(Self.visibleContactLimit).map(\.target))
  }

  private func searchIsCurrent(_ generation: Int, query: String) -> Bool {
    !Task.isCancelled && generation == searchGeneration && normalizedQuery == query
  }

  private func send(_ target: InviteTarget, realtime: RealtimeV2) async throws -> Int64 {
    switch destination {
    case .inline:
      let result = switch target.kind {
      case let .user(info): try await realtime.send(.inviteToInline(userID: info.id))
      case .email: try await realtime.send(.inviteToInline(email: target.value))
      case .phone: try await realtime.send(.inviteToInline(phoneNumber: target.value))
      }
      guard case let .inviteToInline(response) = result else { throw InviteComposerError.invalidResponse }
      return response.user.id

    case let .space(spaceID):
      let access: InviteToSpaceTransaction.Context.AccessRole = accessLevel == .admin
        ? .admin
        : .member(canAccessPublicChats: canAccessPublicChats)
      let result = switch target.kind {
      case let .user(info): try await realtime.send(.inviteToSpace(spaceId: spaceID, access: access, userId: info.id))
      case .email: try await realtime.send(.inviteToSpace(spaceId: spaceID, access: access, email: target.value))
      case .phone: try await realtime.send(.inviteToSpace(spaceId: spaceID, access: access, phoneNumber: target.value))
      }
      guard case let .inviteToSpace(response) = result else { throw InviteComposerError.invalidResponse }
      return response.user.id
    }
  }

  private func inviteFailureDescription(_ error: any Error) -> String {
    guard let realtimeError = error as? RealtimeDirectRpcError else {
      return error.localizedDescription
    }

    return switch realtimeError {
    case let .rpcError(errorCode, _, _):
      switch errorCode {
      case .userIDInvalid:
        "This person can’t be invited. They may be unavailable, or this may be your own email or phone number."
      case .userAlreadyMember:
        "This person is already a member of the space."
      case .emailInvalid:
        "Enter a valid email address."
      case .phoneNumberInvalid:
        "Enter a valid phone number."
      case .spaceAdminRequired:
        "A space admin must send this invitation."
      case .rateLimit:
        "You’ve sent several invitations. Wait a moment and try again."
      default:
        realtimeError.localizedDescription
      }
    case .notAuthorized, .notConnected, .timeout, .commitOutcomeUnknown, .capacityExceeded, .unknown:
      realtimeError.localizedDescription
    }
  }
}

private extension InviteDestination {
  var logKind: String {
    switch self {
    case .inline: "inline"
    case .space: "space"
    }
  }
}

private enum InviteComposerError: Error { case invalidResponse }

struct InviteTarget: Identifiable, Hashable, Sendable {
  enum Kind: Hashable, Sendable {
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

  init(email: String, contactName: String? = nil, isActionable: Bool? = nil) {
    let value = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let isActionable = isActionable ?? inviteEmailIsValid(value)
    id = "email:\(value)"
    kind = .email
    title = contactName ?? value
    detail = contactName == nil
      ? (isActionable ? nil : "Complete the email address")
      : (isActionable ? value : "\(value)  Invalid email")
    self.value = value
    self.isActionable = isActionable
  }

  init(phone: String, contactName: String? = nil) {
    let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
    let digits = phone.filter(\.isNumber)
    let isActionable = (8 ... 15).contains(digits.count)
    let value = isActionable ? "+\(digits)" : trimmed
    id = "phone:\(value)"
    kind = .phone
    title = contactName ?? value
    if contactName != nil {
      // CNPhoneNumber preserves the user's native Contacts formatting. Keep that
      // for display while sending the normalized digits-only value to the API.
      detail = isActionable ? trimmed : "Enter 8–15 digits"
    } else {
      detail = isActionable ? nil : "Enter 8–15 digits"
    }
    self.value = value
    self.isActionable = isActionable
  }

  var symbol: String {
    switch kind {
    case .user: "person.crop.circle"
    case .email: "envelope"
    case .phone: "phone"
    }
  }

  var oneLineTitle: String {
    detail.map { "\(title)  \($0)" } ?? title
  }

  fileprivate var logMechanism: String {
    switch kind {
    case .user: "user"
    case .email: "email"
    case .phone: "phone"
    }
  }
}

struct InviteCompletion: Identifiable, Hashable {
  let target: InviteTarget
  let userID: Int64
  let destination: InviteDestination
  var id: String { target.id }
}

private struct InviteContact: Identifiable, Hashable, Sendable {
  enum Kind: Hashable, Sendable { case email, phone }
  let id: String
  let name: String
  let value: String
  let kind: Kind

  var target: InviteTarget {
    switch kind {
    case .email: InviteTarget(email: value, contactName: name)
    case .phone: InviteTarget(phone: value, contactName: name)
    }
  }

  func matches(_ query: String) -> Bool {
    if name.localizedCaseInsensitiveContains(query) {
      return true
    }
    switch kind {
    case .email:
      return value.localizedCaseInsensitiveContains(query)
    case .phone:
      let queryDigits = query.filter(\.isNumber)
      guard queryDigits.count >= 3 else { return false }
      let significantQuery = queryDigits.drop(while: { $0 == "0" })
      guard !significantQuery.isEmpty else { return false }
      return value.filter(\.isNumber).contains(significantQuery)
    }
  }
}

private actor InviteContactLoader {
  static let shared = InviteContactLoader()

  func load(requestPermission: Bool) async -> Result<[InviteContact], any Error> {
    do {
      let store = CNContactStore()
      if requestPermission {
        guard try await store.requestAccess(for: .contacts) else { return .failure(InviteContactsError.denied) }
      } else {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard inviteContactsAuthorized(status) else {
          return .failure(InviteContactsError.denied)
        }
      }
      let keys = [
        CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey,
        CNContactEmailAddressesKey, CNContactPhoneNumbersKey,
      ] as [CNKeyDescriptor]
      let request = CNContactFetchRequest(keysToFetch: keys)
      var contacts: [InviteContact] = []
      try store.enumerateContacts(with: request) { contact, _ in
        let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        let displayName = name.isEmpty ? "Contact" : name
        for email in contact.emailAddresses {
          contacts.append(.init(id: "\(contact.identifier):\(email.identifier)", name: displayName, value: email.value as String, kind: .email))
        }
        for phone in contact.phoneNumbers {
          contacts.append(.init(id: "\(contact.identifier):\(phone.identifier)", name: displayName, value: phone.value.stringValue, kind: .phone))
        }
      }
      return .success(contacts)
    } catch {
      return .failure(error)
    }
  }
}

private enum InviteContactsError: Error { case denied }

private func inviteEmailIsValid(_ value: String) -> Bool {
  value.range(
    of: #"^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,64}$"#,
    options: .regularExpression
  ) != nil
}

private func inviteContactsAuthorized(_ status: CNAuthorizationStatus) -> Bool {
  #if os(iOS)
  status == .authorized || status == .limited
  #else
  status == .authorized
  #endif
}

// MARK: - Contacts permission

private struct InviteContactsPermissionView: View {
  let isLoading: Bool
  let onAllow: () -> Void
  let onCancel: () -> Void

  @ViewBuilder
  var body: some View {
    #if os(iOS)
    content
      .presentationDetents([.medium])
      .presentationDragIndicator(.visible)
    #else
    content
      .frame(width: 390)
    #endif
  }

  private var content: some View {
    VStack(spacing: 18) {
      Image(systemName: "person.crop.circle.badge.plus")
        .font(.system(size: 40, weight: .medium))
        .foregroundStyle(Color.accentColor)
      Text("Find people from Contacts")
        .font(.title3.weight(.semibold))
      Text("Inline reads names, email addresses, and phone numbers only to suggest invitations on this device. Your address book is not uploaded.")
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      HStack {
        Button("Not Now", action: onCancel)
        Button("Allow Contacts Access", action: onAllow)
          .buttonStyle(.borderedProminent)
          .disabled(isLoading)
      }
    }
    .padding(24)
  }
}

#Preview("General invite") {
  InviteView(destination: .inline)
    .previewsEnvironment(.populated)
}
