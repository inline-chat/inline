import Contacts
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
}

public struct InviteView: View {
  @Environment(\.appDatabase) private var database
  @Environment(\.realtimeV2) private var realtime
  @State private var model: InviteComposerModel

  private let onManageMembers: ((Int64) -> Void)?
  private let onOpenChat: ((InlineKit.Peer) -> Void)?
  private let onCreateSpace: (() -> Void)?

  public init(
    destination: InviteDestination,
    onManageMembers: ((Int64) -> Void)? = nil,
    onOpenChat: ((InlineKit.Peer) -> Void)? = nil,
    onCreateSpace: (() -> Void)? = nil
  ) {
    self.onManageMembers = onManageMembers
    self.onOpenChat = onOpenChat
    self.onCreateSpace = onCreateSpace
    _model = State(initialValue: InviteComposerModel(destination: destination))
  }

  public var body: some View {
    Group {
      #if os(macOS)
      InviteMacView(
        model: model,
        onManageMembers: onManageMembers,
        onOpenChat: onOpenChat,
        onCreateSpace: onCreateSpace
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
  var spaces: [InlineKit.Space] = []
  var query = "" {
    didSet { refreshContactTargets() }
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

  init(destination: InviteDestination) {
    self.destination = destination
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
    guard normalizedQuery.count >= 2, emailSuggestion == nil, phoneTarget == nil else { return [] }
    var seen = Set<Int64>()
    let merged: [InviteTarget] = (localUsers + remoteUsers).compactMap { info in
      guard seen.insert(info.id).inserted else { return nil }
      return InviteTarget(userInfo: info)
    }
    return Array(merged.prefix(20))
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
    guard query.count >= 2, emailSuggestion == nil, phoneTarget == nil else {
      localUsers = []
      remoteUsers = []
      isSearching = false
      return
    }

    isSearching = true
    remoteUsers = []
    let localResults = (try? await InviteDirectory.localUsers(query: query, database: database)) ?? []
    guard searchIsCurrent(generation, query: query) else { return }
    localUsers = localResults

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
    var failures: [String] = []
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
        failures.append(target.title)
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
        ? "The invitation for \(failures[0]) failed."
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
      detail = isActionable ? value : "Enter 8–15 digits"
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
  private static let retainedValueLimit = 250

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
      try store.enumerateContacts(with: request) { contact, stop in
        let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        let displayName = name.isEmpty ? "Contact" : name
        for email in contact.emailAddresses {
          guard contacts.count < Self.retainedValueLimit else {
            stop.pointee = true
            return
          }
          contacts.append(.init(id: "\(contact.identifier):\(email.identifier)", name: displayName, value: email.value as String, kind: .email))
        }
        for phone in contact.phoneNumbers {
          guard contacts.count < Self.retainedValueLimit else {
            stop.pointee = true
            return
          }
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

// MARK: - macOS components

#if os(macOS)
private struct InviteHeader: View {
  let title: String
  let subtitle: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 12)
          .fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing))
        Image(systemName: "person.badge.plus")
          .font(.title2.weight(.semibold))
          .foregroundStyle(.white)
      }
      .frame(width: 46, height: 46)
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.headline)
        Text(subtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(14)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
  }
}

private struct InviteTargetRow: View {
  let target: InviteTarget
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 9) {
        targetArtwork
        Text(target.oneLineTitle)
          .foregroundStyle(.primary)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(selected ? Color.accentColor : Color.secondary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!target.isActionable)
    .opacity(target.isActionable ? 1 : 0.7)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  @ViewBuilder private var targetArtwork: some View {
    switch target.kind {
    case let .user(info):
      UserAvatar(userInfo: info, size: 28)
    case .email, .phone:
      Image(systemName: target.symbol)
        .foregroundStyle(.secondary)
        .frame(width: 28)
    }
  }
}

private struct InvitePrimaryButton: View {
  let count: Int
  let isLoading: Bool
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        if isLoading { ProgressView().controlSize(.small) }
        Text(count == 1 ? "Invite one person" : "Invite \(count) people")
          .fontWeight(.semibold)
      }
      .padding(.horizontal, 22)
      .frame(minHeight: 24)
    }
    .controlSize(.large)
    .buttonBorderShape(.capsule)
    .disabled(count == 0 || isLoading)
    .modifier(InviteProminentButtonStyle())
  }
}

private struct InviteProminentButtonStyle: ViewModifier {
  @ViewBuilder func body(content: Content) -> some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      content.buttonStyle(.glassProminent)
    } else {
      content.buttonStyle(.borderedProminent)
    }
  }
}

private struct InviteSelectionTokens: View {
  let targets: [InviteTarget]
  let onRemove: (InviteTarget) -> Void

  var body: some View {
    if !targets.isEmpty {
      ScrollView(.horizontal) {
        if #available(iOS 26.0, macOS 26.0, *) {
          GlassEffectContainer(spacing: 7) {
            InviteSelectionTokenRow(targets: targets, onRemove: onRemove)
          }
        } else {
          InviteSelectionTokenRow(targets: targets, onRemove: onRemove)
        }
      }
      .scrollIndicators(.hidden)
    }
  }
}

private struct InviteSelectionTokenRow: View {
  let targets: [InviteTarget]
  let onRemove: (InviteTarget) -> Void

  var body: some View {
    HStack(spacing: 7) {
      ForEach(targets) { target in
        InviteSelectionToken(target: target) { onRemove(target) }
      }
    }
    .padding(.vertical, 2)
  }
}

private struct InviteSelectionToken: View {
  let target: InviteTarget
  let onRemove: () -> Void

  var body: some View {
    let label = Button(action: onRemove) {
      HStack(spacing: 6) {
        InviteTargetTokenArtwork(target: target)
        Text(target.title)
          .font(.subheadline)
          .lineLimit(1)
        Image(systemName: "xmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.leading, 7)
      .padding(.trailing, 6)
      .frame(height: 30)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Remove \(target.title) from invitation")

    if #available(iOS 26.0, macOS 26.0, *) {
      label.glassEffect(.regular.interactive(), in: .capsule)
    } else {
      label.background(.quaternary, in: Capsule())
    }
  }
}

private struct InviteTargetTokenArtwork: View {
  let target: InviteTarget

  var body: some View {
    HStack {
      switch target.kind {
      case let .user(info):
        UserAvatar(userInfo: info, size: 20)
      case .email, .phone:
        Image(systemName: target.symbol)
          .font(.caption)
          .frame(width: 20)
      }
    }
  }
}

private struct InviteDestinationSettings: View {
  @Bindable var model: InviteComposerModel
  let onCreateSpace: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      Picker("Invite to", selection: $model.destination) {
        Text("Inline — start a chat").tag(InviteDestination.inline)
        ForEach(model.spaces) { space in
          Text(space.displayName).tag(InviteDestination.space(id: space.id))
        }
      }
      .pickerStyle(.menu)
      .disabled(model.isSending)

      switch model.destination {
      case .inline:
        Text("Creating a team or community? Create a space, then invite everyone into it.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if let onCreateSpace {
          Button("Create a space", systemImage: "person.3") {
            onCreateSpace()
          }
          .buttonStyle(.plain)
          .font(.callout.weight(.medium))
          .foregroundStyle(.tint)
        }
      case .space:
        if model.selected.isEmpty {
          Text("Select people to configure their space access.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Divider()
          Picker("Access", selection: $model.accessLevel) {
            ForEach(InviteComposerModel.AccessLevel.allCases) { level in
              Text(level.title).tag(level)
            }
          }
          .pickerStyle(.menu)
          if model.accessLevel == .member {
            Toggle("Can access all public chats", isOn: $model.canAccessPublicChats)
          }
        }
      }
    }
    .padding(14)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
  }
}
#endif

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

#if os(macOS)
private struct InviteSearchField: View {
  @Bindable var model: InviteComposerModel

  var body: some View {
    let field = HStack(spacing: 9) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      searchTextField
      if model.isSearching {
        ProgressView()
          .controlSize(.small)
      }
      if !model.query.isEmpty {
        Button("Clear", systemImage: "xmark.circle.fill") { model.query = "" }
          .labelStyle(.iconOnly)
          .buttonStyle(.plain)
          .foregroundStyle(.tertiary)
      }
      Divider()
        .frame(height: 18)
      Button("Find from Contacts", systemImage: "person.crop.circle.badge.plus") {
        model.showContacts()
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 13)
    .frame(height: 40)

    if #available(iOS 26.0, macOS 26.0, *) {
      field.glassEffect(.regular.interactive(), in: .capsule)
    } else {
      field
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().stroke(.separator.opacity(0.6), lineWidth: 0.5) }
    }
  }

  @ViewBuilder private var searchTextField: some View {
    TextField("Search by username, or invite by email or phone", text: $model.query)
      .textFieldStyle(.plain)
  }
}
#endif

// MARK: - macOS

#if os(macOS)
private struct InviteMacView: View {
  @Bindable var model: InviteComposerModel
  @Environment(\.realtimeV2) private var realtime
  let onManageMembers: ((Int64) -> Void)?
  let onOpenChat: ((InlineKit.Peer) -> Void)?
  let onCreateSpace: (() -> Void)?

  var body: some View {
    if model.showsOutcome {
      InviteOutcomeView(
        model: model,
        onOpenChat: onOpenChat,
        onManageMembers: onManageMembers
      )
      .toolbar {
        ToolbarItem(placement: .navigation) {
          Button("Back to Invite", systemImage: "chevron.backward") {
            model.returnToInvite()
          }
        }
      }
    } else {
      InviteMacComposer(model: model, onCreateSpace: onCreateSpace)
        .safeAreaInset(edge: .bottom) {
          if !model.selected.isEmpty {
            InvitePrimaryButton(count: model.selected.count, isLoading: model.isSending) {
              Task { await model.invite(realtime: realtime) }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
          }
        }
    }
  }
}

private struct InviteMacComposer: View {
  @Bindable var model: InviteComposerModel
  let onCreateSpace: (() -> Void)?

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        InviteHeader(title: model.title, subtitle: model.subtitle)
        InviteSearchField(model: model)
        InviteSelectionTokens(targets: model.selected, onRemove: model.toggle)
        if model.hasSuggestions || !model.normalizedQuery.isEmpty || model.isSearching {
          ScrollView {
            InviteSuggestionSections(model: model)
              .padding(12)
          }
          .frame(height: 230)
          .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 12))
        }
        InviteDestinationSettings(model: model, onCreateSpace: onCreateSpace)
      }
      .frame(maxWidth: 560)
      .padding(24)
      .padding(.bottom, 60)
      .frame(maxWidth: .infinity)
    }
  }
}

private struct InviteSuggestionSections: View {
  let model: InviteComposerModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      InviteSuggestionGroup(title: "Invite users", targets: model.userTargets, model: model)
      InviteSuggestionGroup(title: "Contacts", targets: model.contactTargets, model: model)
      InviteSuggestionGroup(
        title: "Send email invite",
        targets: model.emailSuggestion.map { [$0] } ?? [],
        model: model
      )
      InviteSuggestionGroup(
        title: "Invite phone number",
        targets: model.phoneTarget.map { [$0] } ?? [],
        model: model
      )
      if let message = model.emptyResultMessage {
        Text(message)
          .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
          .frame(maxWidth: .infinity).frame(minHeight: 42)
      }
    }
  }
}

private struct InviteSuggestionGroup: View {
  let title: LocalizedStringResource
  let targets: [InviteTarget]
  let model: InviteComposerModel

  var body: some View {
    if !targets.isEmpty {
      VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        ForEach(targets) { target in
          InviteTargetRow(target: target, selected: model.isSelected(target)) { model.toggle(target) }
            .frame(height: 32)
            .padding(.horizontal, 8)
            .background(model.isSelected(target) ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
      }
    }
  }
}
#endif

// MARK: - macOS outcome

#if os(macOS)
private struct InviteOutcomeView: View {
  let model: InviteComposerModel
  let onOpenChat: ((InlineKit.Peer) -> Void)?
  let onManageMembers: ((Int64) -> Void)?

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        InviteHeader(
          title: "Invitations are on their way",
          subtitle: outcomeSubtitle
        )
        InviteOutcomeGroup(
          title: model.isSpaceInvite ? "Added to the space" : "Ready to chat",
          description: model.isSpaceInvite
            ? "These people can open the space now."
            : "These people are already on Inline, so their chat is ready.",
          completions: model.peopleCompletions,
          model: model,
          onOpenChat: onOpenChat
        )
        InviteOutcomeGroup(
          title: "Email sent",
          description: model.isSpaceInvite
            ? "They’ll join this space after accepting and signing in."
            : "They can join Inline from the email and continue in your shared chat.",
          completions: model.emailCompletions,
          model: model,
          onOpenChat: onOpenChat
        )
        InviteOutcomeGroup(
          title: "Share these invitations",
          description: model.isSpaceInvite
            ? "Send each person an invite message. After joining Inline, they’ll be part of this space."
            : "Send each person an invite message so they can join Inline and start chatting with you.",
          completions: model.phoneCompletions,
          model: model,
          onOpenChat: onOpenChat
        )
        if case let .space(spaceID) = model.destination, let onManageMembers {
          Button("Manage Members", systemImage: "person.3") {
            onManageMembers(spaceID)
          }
        }
      }
      .frame(maxWidth: 560)
      .padding(24)
      .frame(maxWidth: .infinity)
    }
    .navigationTitle("Invitation results")
  }

  private var outcomeSubtitle: String {
    switch model.destination {
    case .inline:
      "Inline handled each person in the way that fits how you invited them."
    case .space:
      "Review who was added, which emails were sent, and which invitations still need sharing."
    }
  }
}

private struct InviteOutcomeGroup: View {
  let title: LocalizedStringResource
  let description: LocalizedStringResource
  let completions: [InviteCompletion]
  let model: InviteComposerModel
  let onOpenChat: ((InlineKit.Peer) -> Void)?

  var body: some View {
    if !completions.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text(title)
          .font(.headline)
        Text(description)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        VStack(spacing: 0) {
          ForEach(completions) { completion in
            InviteOutcomeRow(model: model, completion: completion, onOpenChat: onOpenChat)
            if completion.id != completions.last?.id {
              Divider().padding(.leading, 31)
            }
          }
        }
        .padding(.horizontal, 10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct InviteOutcomeRow: View {
  let model: InviteComposerModel
  let completion: InviteCompletion
  let onOpenChat: ((InlineKit.Peer) -> Void)?
  @Environment(\.realtimeV2) private var realtime
  @State private var hoveringAction = false

  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: completion.target.symbol).foregroundStyle(.secondary).frame(width: 22)
      Text(completion.target.oneLineTitle).lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)

      if case .phone = completion.target.kind {
        ShareLink(item: inviteMessage) {
          Label("Share", systemImage: "square.and.arrow.up")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
      } else if case .inline = completion.destination,
                case .user = completion.target.kind,
                let onOpenChat {
        Button("Open Chat") { onOpenChat(.user(id: completion.userID)) }
      }

      if case .space = completion.destination {
        Button {
          Task { await model.revoke(completion, realtime: realtime) }
        } label: {
          Image(systemName: hoveringAction ? "xmark.circle.fill" : "checkmark.circle.fill")
            .foregroundStyle(hoveringAction ? .red : .green)
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { hoveringAction = $0 }
        #endif
        .accessibilityLabel("Revoke invitation for \(completion.target.title)")
      } else {
        if case .phone = completion.target.kind {
          EmptyView()
        } else if case .user = completion.target.kind, onOpenChat != nil {
          EmptyView()
        } else {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
      }
    }
    .frame(minHeight: 38)
  }

  private var inviteMessage: String {
    switch completion.destination {
    case .inline: "Join me on Inline so we can chat: https://inline.chat/download"
    case .space: "Join me on Inline in \(model.name(for: completion.destination) ?? "our space"): https://inline.chat/download"
    }
  }
}
#endif

#Preview("General invite") {
  InviteView(destination: .inline)
    .previewsEnvironment(.populated)
}
