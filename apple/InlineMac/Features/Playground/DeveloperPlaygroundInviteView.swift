#if DEBUG || DEBUG_BUILD
import AppKit
import Contacts
import InlineUI
import SwiftUI

enum DeveloperInviteLayout: String, CaseIterable, Identifiable {
  case focused
  case split
  case directory
  case guided
  case compact

  var id: Self { self }

  var title: String {
    switch self {
    case .focused: "1. Focused card"
    case .split: "2. Split view"
    case .directory: "3. People first"
    case .guided: "4. Guided flow"
    case .compact: "5. Compact sheet"
    }
  }

  var shortTitle: String {
    switch self {
    case .focused: "Focused"
    case .split: "Split"
    case .directory: "People"
    case .guided: "Guided"
    case .compact: "Compact"
    }
  }

  var detail: String {
    switch self {
    case .focused:
      "A calm, centered card that puts one invite action at the center of the page."
    case .split:
      "Workspace context and access guidance on the left, with the actionable form on the right."
    case .directory:
      "Search and people are the main surface; permissions become a compact supporting control."
    case .guided:
      "Method, access, and confirmation are presented as three explicit stages at once."
    case .compact:
      "A dense sheet-style layout for fast keyboard-driven invites with minimal ceremony."
    }
  }
}

struct DeveloperPlaygroundInviteView: View {
  @Binding var selectedLayout: DeveloperInviteLayout
  @State private var previewState = DeveloperInvitePreviewState()

  var body: some View {
    VStack(spacing: 0) {
      DeveloperInvitePlaygroundHeader(selectedLayout: $selectedLayout)

      Divider()

      ScrollView {
        Group {
          switch selectedLayout {
          case .focused:
            DeveloperInviteFocusedLayout(state: $previewState)
          case .split:
            DeveloperInviteSplitLayout(state: $previewState)
          case .directory:
            DeveloperInviteDirectoryLayout(state: $previewState)
          case .guided:
            DeveloperInviteGuidedLayout(state: $previewState)
          case .compact:
            DeveloperInviteCompactLayout(state: $previewState)
          }
        }
        .frame(maxWidth: .infinity, minHeight: 520, alignment: .top)
        .padding(28)
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

private struct DeveloperInvitePlaygroundHeader: View {
  @Binding var selectedLayout: DeveloperInviteLayout

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text("Invite page experiment")
            .font(.title2.weight(.semibold))
          Text("TEMPORARY")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.1), in: Capsule())
        }
        Text("August 13th, 2026 · Five arrangements of the same invite capabilities. Actions are local fixtures.")
          .foregroundStyle(.secondary)
      }

      Picker("Layout", selection: $selectedLayout) {
        ForEach(DeveloperInviteLayout.allCases) { layout in
          Text(verbatim: layout.shortTitle)
            .tag(layout)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 24)
    .padding(.vertical, 18)
  }
}

private struct DeveloperInvitePreviewState {
  var method = DeveloperInviteMethod.username
  var role = DeveloperInviteRole.member
  var canAccessPublicChats = true
  var username = "alex"
  var email = "preview@example.com"
  var phone = "+1 415 555 0128"
  var selectedUserID: Int64? = 201
  var unifiedQuery = "alex"
  var selectedTargets: [DeveloperInviteTarget] = []
  var justInvited: [DeveloperInviteTarget] = [
    .init(
      id: "user:204",
      kind: .user,
      title: "Mina Park",
      detail: "@minapark",
      symbol: "person.crop.circle"
    ),
  ]
}

private struct DeveloperInviteTarget: Identifiable, Hashable, Sendable {
  enum Kind: Hashable, Sendable {
    case user
    case email
    case phone
  }

  let id: String
  let kind: Kind
  let title: String
  let detail: String?
  let symbol: String

  var compactTitle: String {
    if let detail, detail.isEmpty == false {
      return "\(title)  \(detail)"
    }
    return title
  }
}

private enum DeveloperInviteMethod: String, CaseIterable, Identifiable {
  case username
  case email
  case phone

  var id: Self { self }

  var title: String {
    switch self {
    case .username: "Username"
    case .email: "Email"
    case .phone: "Phone"
    }
  }

  var iconName: String {
    switch self {
    case .username: "at"
    case .email: "envelope"
    case .phone: "phone"
    }
  }
}

private enum DeveloperInviteRole: String, CaseIterable, Identifiable {
  case member
  case admin

  var id: Self { self }

  var title: String {
    switch self {
    case .member: "Member"
    case .admin: "Admin"
    }
  }
}

private struct DeveloperInviteFocusedLayout: View {
  @Binding var state: DeveloperInvitePreviewState
  @State private var importedContacts: [DeveloperInviteContact] = []
  @State private var contactsState = DeveloperContactsState.idle
  @State private var isShowingContactsPermission = false

  var body: some View {
    VStack(spacing: 26) {
      DeveloperInviteSettingsHeader()

      DeveloperInviteCard {
        VStack(alignment: .leading, spacing: 16) {
          DeveloperInviteUnifiedInput(
            query: $state.unifiedQuery,
            contactsState: contactsState,
            onOpenContacts: { isShowingContactsPermission = true }
          )

          DeveloperInviteAutocomplete(
            query: state.unifiedQuery,
            contacts: importedContacts,
            selectedTargets: state.selectedTargets,
            onToggle: toggleTarget
          )

          if state.selectedTargets.isEmpty == false {
            Divider()
            DeveloperInviteSelectionAccessForm(
              state: $state,
              onRemove: toggleTarget
            )

            HStack {
              DeveloperInviteFocusedPrimaryButton(
                count: state.selectedTargets.count,
                action: inviteSelected
              )
            }
            .frame(maxWidth: .infinity, alignment: .center)
          }

          if contactsState == .denied {
            Text("Contacts access is off. You can enable it in System Settings.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .frame(maxWidth: 560)

      if state.justInvited.isEmpty == false {
        DeveloperInviteJustInvited(targets: state.justInvited) { target in
          withAnimation(.snappy(duration: 0.18)) {
            state.justInvited.removeAll { $0.id == target.id }
          }
        }
        .frame(maxWidth: 560)
      }
    }
    .frame(maxWidth: .infinity)
    .sheet(isPresented: $isShowingContactsPermission) {
      DeveloperInviteContactsPermissionSheet(
        contactsState: contactsState,
        onAllow: {
          isShowingContactsPermission = false
          importContacts()
        },
        onCancel: { isShowingContactsPermission = false }
      )
    }
  }

  private func toggleTarget(_ target: DeveloperInviteTarget) {
    if let index = state.selectedTargets.firstIndex(where: { $0.id == target.id }) {
      state.selectedTargets.remove(at: index)
    } else {
      state.selectedTargets.append(target)
    }
  }

  private func inviteSelected() {
    withAnimation(.snappy(duration: 0.18)) {
      let newTargets = state.selectedTargets.filter { selected in
        state.justInvited.contains(where: { $0.id == selected.id }) == false
      }
      state.justInvited.insert(contentsOf: newTargets, at: 0)
      state.selectedTargets.removeAll()
    }
  }

  private func importContacts() {
    contactsState = .loading
    Task {
      let result = await DeveloperContactLoader.shared.load()
      switch result {
      case let .success(contacts):
        importedContacts = contacts
        contactsState = .loaded
      case .failure:
        contactsState = .denied
      }
    }
  }
}

private struct DeveloperInviteSettingsHeader: View {
  var body: some View {
    VStack(spacing: 10) {
      DeveloperInviteHeaderMark(size: 76)

      VStack(spacing: 3) {
        Text("Invite to Acme Design")
          .font(.title2.weight(.semibold))
        Text("Find an Inline user or invite someone by email, phone, or your contacts.")
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: 560)
  }
}

private struct DeveloperInviteHeaderMark: View {
  let size: CGFloat

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.28)
        .fill(
          LinearGradient(
            colors: [Color.accentColor, Color.accentColor.opacity(0.72)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
      Image(systemName: "person.badge.plus")
        .font(.system(size: size * 0.42, weight: .semibold))
        .foregroundStyle(.white)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

private struct DeveloperInviteUnifiedInput: View {
  @Binding var query: String
  let contactsState: DeveloperContactsState
  let onOpenContacts: () -> Void

  @ViewBuilder
  var body: some View {
    let field = HStack(spacing: 9) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField("Search by username, or invite by email or phone", text: $query)
        .textFieldStyle(.plain)
      if query.isEmpty == false {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.leading, 13)
    .padding(.trailing, 54)
    .frame(height: 40)
    .contentShape(Capsule())
    .overlay(alignment: .trailing) {
      HStack(spacing: 9) {
        Divider()
          .frame(height: 18)

        if contactsState == .loading {
          ProgressView()
            .controlSize(.small)
            .frame(width: 20)
            .accessibilityLabel("Loading Contacts")
        } else {
          Button(action: onOpenContacts) {
            Image(systemName: "person.crop.circle.badge.plus")
              .foregroundStyle(.secondary)
              .frame(width: 20, height: 20)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Find from Contacts")
          .help("Find from Contacts")
        }
      }
      .padding(.trailing, 13)
    }

    if #available(macOS 26.0, *) {
      field
        .glassEffect(.regular.interactive(), in: .capsule)
    } else {
      field
        .background(.regularMaterial, in: Capsule())
        .overlay {
          Capsule()
            .stroke(Color(nsColor: .separatorColor).opacity(0.75), lineWidth: 0.5)
        }
    }
  }
}

private struct DeveloperInviteAutocomplete: View {
  let query: String
  let contacts: [DeveloperInviteContact]
  let selectedTargets: [DeveloperInviteTarget]
  let onToggle: (DeveloperInviteTarget) -> Void

  private let users = [
    DeveloperInvitePerson(id: 201, firstName: "Alex", lastName: "Morgan", username: "alex"),
    DeveloperInvitePerson(id: 202, firstName: "Alexandra", lastName: "Chen", username: "alexandra"),
    DeveloperInvitePerson(id: 203, firstName: "Alexander", lastName: "Singh", username: "asingh"),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if matchingUsers.isEmpty == false {
        DeveloperInviteTargetSection(title: "Invite users") {
          ForEach(matchingUsers) { target in
            DeveloperInviteCompactTargetRow(
              target: target,
              selected: isSelected(target),
              onToggle: onToggle
            )
          }
        }
      }

      if matchingContacts.isEmpty == false {
        DeveloperInviteTargetSection(title: "Contacts") {
          ForEach(matchingContacts) { target in
            DeveloperInviteCompactTargetRow(
              target: target,
              selected: isSelected(target),
              onToggle: onToggle
            )
          }
        }
      }

      if let emailTarget {
        DeveloperInviteTargetSection(title: "Send email invite") {
          DeveloperInviteCompactTargetRow(
            target: emailTarget,
            selected: isSelected(emailTarget),
            onToggle: onToggle
          )
        }
      }

      if let phoneTarget {
        DeveloperInviteTargetSection(title: "Invite phone number") {
          DeveloperInviteCompactTargetRow(
            target: phoneTarget,
            selected: isSelected(phoneTarget),
            onToggle: onToggle
          )
        }
      }

      if normalizedQuery.isEmpty == false, hasResults == false {
        Text("Enter at least two username characters, an email, or a phone number.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity)
          .frame(minHeight: 42)
      }
    }
  }

  private var normalizedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var matchingUsers: [DeveloperInviteTarget] {
    let needle = normalizedQuery.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
    guard needle.count >= 2, emailTarget == nil, phoneTarget == nil else { return [] }
    return users
      .filter {
        $0.username.localizedCaseInsensitiveContains(needle)
          || "\($0.firstName) \($0.lastName)".localizedCaseInsensitiveContains(needle)
      }
      .map {
        .init(
          id: "user:\($0.id)",
          kind: .user,
          title: "\($0.firstName) \($0.lastName)",
          detail: "@\($0.username)",
          symbol: "person.crop.circle"
        )
      }
  }

  private var matchingContacts: [DeveloperInviteTarget] {
    guard normalizedQuery.isEmpty == false else { return [] }
    return contacts
      .filter { $0.matches(normalizedQuery) }
      .prefix(5)
      .map(\.inviteTarget)
  }

  private var emailTarget: DeveloperInviteTarget? {
    guard normalizedQuery.contains("@"), normalizedQuery.contains(" ") == false else { return nil }
    return .init(
      id: "email:\(normalizedQuery.lowercased())",
      kind: .email,
      title: normalizedQuery,
      detail: nil,
      symbol: "envelope"
    )
  }

  private var phoneTarget: DeveloperInviteTarget? {
    let digits = normalizedQuery.filter(\.isNumber)
    guard digits.count >= 7, normalizedQuery.contains("@") == false else { return nil }
    return .init(
      id: "phone:\(digits)",
      kind: .phone,
      title: normalizedQuery,
      detail: nil,
      symbol: "phone"
    )
  }

  private var hasResults: Bool {
    matchingUsers.isEmpty == false || matchingContacts.isEmpty == false
      || emailTarget != nil || phoneTarget != nil
  }

  private func isSelected(_ target: DeveloperInviteTarget) -> Bool {
    selectedTargets.contains { $0.id == target.id }
  }
}

private struct DeveloperInviteTargetSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
      VStack(spacing: 1) {
        content
      }
    }
  }
}

private struct DeveloperInviteCompactTargetRow: View {
  let target: DeveloperInviteTarget
  let selected: Bool
  let onToggle: (DeveloperInviteTarget) -> Void

  var body: some View {
    Button {
      onToggle(target)
    } label: {
      HStack(spacing: 9) {
        if target.kind == .user {
          UserAvatar(
            userID: userID,
            firstName: target.title,
            lastName: nil,
            email: nil,
            username: target.detail,
            stableAvatarIdentity: nil,
            remoteURL: nil,
            localURL: nil,
            size: 24,
            cacheRemoteAvatar: false
          )
          .frame(width: 24)
        } else {
          Image(systemName: target.symbol)
            .foregroundStyle(.secondary)
            .frame(width: 24)
        }
        Text(target.compactTitle)
          .font(.subheadline)
          .foregroundStyle(.primary)
          .lineLimit(1)
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(selected ? Color.accentColor : Color.secondary)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
      .contentShape(Rectangle())
      .padding(.horizontal, 8)
      .frame(height: 32)
      .background(selected ? Color.accentColor.opacity(0.08) : Color.clear)
    }
    .buttonStyle(.plain)
  }

  private var userID: Int64 {
    Int64(target.id.split(separator: ":").last ?? "") ?? 0
  }
}

private struct DeveloperInviteSelectionAccessForm: View {
  @Binding var state: DeveloperInvitePreviewState
  let onRemove: (DeveloperInviteTarget) -> Void

  var body: some View {
    Form {
      Section {
        ForEach(state.selectedTargets) { target in
          DeveloperInviteSelectedTargetRow(target: target, onRemove: onRemove)
        }
      } header: {
        Text(sectionTitle)
      }

      Section("Access") {
        Picker("Access", selection: $state.role) {
          ForEach(DeveloperInviteRole.allCases) { role in
            Text(verbatim: role.title)
              .tag(role)
          }
        }

        if state.role == .member {
          Toggle("Can access all public chats", isOn: $state.canAccessPublicChats)
        }
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .scrollDisabled(state.selectedTargets.count <= 5)
    .frame(height: min(330, 168 + CGFloat(state.selectedTargets.count) * 34))
  }

  private var sectionTitle: LocalizedStringResource {
    state.selectedTargets.count == 1
      ? "Inviting one person"
      : "Inviting \(state.selectedTargets.count) people"
  }
}

private struct DeveloperInviteSelectedTargetRow: View {
  let target: DeveloperInviteTarget
  let onRemove: (DeveloperInviteTarget) -> Void

  var body: some View {
    HStack(spacing: 9) {
      if target.kind == .user {
        UserAvatar(
          userID: userID,
          firstName: target.title,
          lastName: nil,
          email: nil,
          username: target.detail,
          stableAvatarIdentity: nil,
          remoteURL: nil,
          localURL: nil,
          size: 22,
          cacheRemoteAvatar: false
        )
        .frame(width: 22)
      } else {
        Image(systemName: target.symbol)
          .foregroundStyle(.secondary)
          .frame(width: 22)
      }
      Text(target.compactTitle)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button {
        onRemove(target)
      } label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.tertiary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Remove \(target.title) from invitation")
    }
  }

  private var userID: Int64 {
    Int64(target.id.split(separator: ":").last ?? "") ?? 0
  }
}

private struct DeveloperInviteFocusedPrimaryButton: View {
  let count: Int
  let action: () -> Void

  @ViewBuilder
  var body: some View {
    let button = Button(action: action) {
      Text(title)
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 20)
    }
    .controlSize(.large)
    .buttonBorderShape(.capsule)
    .overlay {
      ButtonShineOverlay(active: true)
    }
    .clipShape(Capsule())

    if #available(macOS 26.0, *) {
      button
        .buttonStyle(.glassProminent)
    } else {
      button
        .buttonStyle(.borderedProminent)
    }
  }

  private var title: LocalizedStringResource {
    count == 1 ? "Invite one person" : "Invite \(count) people"
  }
}

private struct DeveloperInviteContactsPermissionSheet: View {
  let contactsState: DeveloperContactsState
  let onAllow: () -> Void
  let onCancel: () -> Void

  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "person.crop.circle.badge.plus")
        .font(.system(size: 38, weight: .medium))
        .foregroundStyle(Color.accentColor)

      VStack(spacing: 6) {
        Text("Find people from Contacts")
          .font(.title3.weight(.semibold))
        Text("Inline will read names, email addresses, and phone numbers from Contacts to suggest invitations. Matching stays on this Mac.")
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 10) {
        Button("Not Now", action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button(allowButtonTitle, action: onAllow)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 380)
  }

  private var allowButtonTitle: LocalizedStringResource {
    contactsState == .loaded ? "Refresh Contacts" : "Allow Contacts Access"
  }
}

private struct DeveloperInviteJustInvited: View {
  let targets: [DeveloperInviteTarget]
  let onRevoke: (DeveloperInviteTarget) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text("Just invited")
        .font(.headline)

      VStack(spacing: 1) {
        ForEach(targets) { target in
          DeveloperInviteCompletedRow(target: target, onRevoke: onRevoke)
        }
      }
      .padding(6)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
  }
}

private struct DeveloperInviteCompletedRow: View {
  let target: DeveloperInviteTarget
  let onRevoke: (DeveloperInviteTarget) -> Void
  @State private var isHoveringAction = false

  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: target.symbol)
        .foregroundStyle(.secondary)
        .frame(width: 22)
      Text(target.compactTitle)
        .font(.subheadline)
        .lineLimit(1)
      Button {
        onRevoke(target)
      } label: {
        Image(systemName: isHoveringAction ? "xmark.circle.fill" : "checkmark.circle.fill")
          .foregroundStyle(isHoveringAction ? Color.red : Color.green)
      }
      .buttonStyle(.plain)
      .onHover { isHoveringAction = $0 }
      .accessibilityLabel("Revoke invitation for \(target.title)")
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .padding(.horizontal, 8)
    .frame(height: 32)
  }
}

private struct DeveloperInviteContact: Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  let value: String
  let kind: DeveloperInviteTarget.Kind

  var inviteTarget: DeveloperInviteTarget {
    .init(
      id: "contact:\(id):\(value)",
      kind: kind,
      title: name,
      detail: value,
      symbol: kind == .email ? "envelope" : "phone"
    )
  }

  func matches(_ query: String) -> Bool {
    name.localizedCaseInsensitiveContains(query) || value.localizedCaseInsensitiveContains(query)
  }
}

private enum DeveloperContactsState {
  case idle
  case loading
  case loaded
  case denied
}

private actor DeveloperContactLoader {
  static let shared = DeveloperContactLoader()

  func load() async -> Result<[DeveloperInviteContact], any Error> {
    let store = CNContactStore()

    do {
      let granted = try await requestAccess(using: store)
      guard granted else { return .failure(DeveloperContactError.accessDenied) }

      let keys = [
        CNContactIdentifierKey,
        CNContactGivenNameKey,
        CNContactFamilyNameKey,
        CNContactEmailAddressesKey,
        CNContactPhoneNumbersKey,
      ] as [CNKeyDescriptor]
      let request = CNContactFetchRequest(keysToFetch: keys)
      var results: [DeveloperInviteContact] = []

      try store.enumerateContacts(with: request) { contact, _ in
        let name = [contact.givenName, contact.familyName]
          .filter { $0.isEmpty == false }
          .joined(separator: " ")
        let displayName = name.isEmpty ? "Contact" : name

        if let email = contact.emailAddresses.first?.value as String? {
          results.append(.init(
            id: contact.identifier,
            name: displayName,
            value: email,
            kind: .email
          ))
        } else if let phone = contact.phoneNumbers.first?.value.stringValue {
          results.append(.init(
            id: contact.identifier,
            name: displayName,
            value: phone,
            kind: .phone
          ))
        }
      }

      return .success(results)
    } catch {
      return .failure(error)
    }
  }

  private func requestAccess(using store: CNContactStore) async throws -> Bool {
    try await withCheckedThrowingContinuation { continuation in
      store.requestAccess(for: .contacts) { granted, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: granted)
        }
      }
    }
  }
}

private enum DeveloperContactError: Error {
  case accessDenied
}

private struct DeveloperInviteSplitLayout: View {
  @Binding var state: DeveloperInvitePreviewState

  var body: some View {
    DeveloperInviteCard {
      HStack(alignment: .top, spacing: 0) {
        VStack(alignment: .leading, spacing: 24) {
          DeveloperInviteHeroHeader(centered: false)

          VStack(alignment: .leading, spacing: 14) {
            DeveloperInviteContextRow(
              iconName: "person.2",
              title: "Bring your team together",
              detail: "Invite existing Inline users or reach someone by email or phone."
            )
            DeveloperInviteContextRow(
              iconName: "bubble.left.and.bubble.right",
              title: "Public chats included",
              detail: "Members can discover public chats. Private chats still require an explicit add."
            )
            DeveloperInviteContextRow(
              iconName: "person.3",
              title: "12 members",
              detail: "You can review access after sending the invite."
            )
          }

          Button("Manage members") {}
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(28)

        Divider()

        VStack(alignment: .leading, spacing: 18) {
          Text("Who do you want to invite?")
            .font(.headline)
          DeveloperInviteMethodPicker(method: $state.method)
          DeveloperInviteInput(state: $state)

          if state.method == .username {
            DeveloperInviteResults(state: $state, presentation: .rows)
          }

          DeveloperInviteAccessControls(state: $state, compact: true)
          DeveloperInvitePrimaryButton(state: state)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(28)
      }
    }
    .frame(maxWidth: 820)
  }
}

private struct DeveloperInviteDirectoryLayout: View {
  @Binding var state: DeveloperInvitePreviewState

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(alignment: .center, spacing: 16) {
        DeveloperInviteHeroHeader(centered: false)

        Button("Manage members") {}
      }

      DeveloperInviteCard {
        VStack(alignment: .leading, spacing: 18) {
          HStack(alignment: .bottom, spacing: 16) {
            DeveloperInviteMethodPicker(method: $state.method)
              .frame(maxWidth: 360)
            DeveloperInviteInput(state: $state)
          }

          DeveloperInviteDestinationPanel(state: $state)

          Divider()

          ViewThatFits {
            HStack(spacing: 18) {
              DeveloperInviteAccessControls(state: $state, compact: true)
              DeveloperInvitePrimaryButton(state: state, width: 190)
            }

            VStack(spacing: 14) {
              DeveloperInviteAccessControls(state: $state, compact: true)
              DeveloperInvitePrimaryButton(state: state)
            }
          }
        }
      }
    }
    .frame(maxWidth: 820)
  }
}

private struct DeveloperInviteGuidedLayout: View {
  @Binding var state: DeveloperInvitePreviewState

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      DeveloperInviteHeroHeader(centered: false)

      ViewThatFits {
        HStack(alignment: .top, spacing: 12) {
          DeveloperInviteStepCard(number: 1, title: "Choose a person") {
            DeveloperInviteMethodPicker(method: $state.method)
            DeveloperInviteInput(state: $state)
            if state.method == .username {
              DeveloperInviteResults(state: $state, presentation: .compact)
            }
          }

          DeveloperInviteStepCard(number: 2, title: "Set their access") {
            DeveloperInviteAccessControls(state: $state, compact: false)
          }

          DeveloperInviteStepCard(number: 3, title: "Review and send") {
            DeveloperInviteSummary(state: state)
            DeveloperInvitePrimaryButton(state: state)
          }
        }

        VStack(spacing: 12) {
          DeveloperInviteStepCard(number: 1, title: "Choose a person") {
            DeveloperInviteMethodPicker(method: $state.method)
            DeveloperInviteInput(state: $state)
          }
          DeveloperInviteStepCard(number: 2, title: "Set their access") {
            DeveloperInviteAccessControls(state: $state, compact: true)
          }
          DeveloperInviteStepCard(number: 3, title: "Review and send") {
            DeveloperInviteSummary(state: state)
            DeveloperInvitePrimaryButton(state: state)
          }
        }
      }

      Button("Manage current members") {}
        .buttonStyle(.link)
        .frame(maxWidth: .infinity)
    }
    .frame(maxWidth: 900)
  }
}

private struct DeveloperInviteCompactLayout: View {
  @Binding var state: DeveloperInvitePreviewState

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        DeveloperInviteWorkspaceMark(size: 42)

        VStack(alignment: .leading, spacing: 2) {
          Text("Invite to Acme Design")
            .font(.headline)
          Text("Add someone to your workspace")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        Button("Members") {}
          .buttonStyle(.link)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
      .padding(20)

      Divider()

      VStack(spacing: 0) {
        DeveloperInviteCompactPickerRow(
          title: "Invite via",
          iconName: state.method.iconName
        ) {
          Picker("Invite via", selection: $state.method) {
            ForEach(DeveloperInviteMethod.allCases) { method in
              Text(verbatim: method.title)
                .tag(method)
            }
          }
          .labelsHidden()
          .frame(width: 120)
        }

        Divider()
          .padding(.leading, 44)

        DeveloperInviteInput(state: $state, compact: true)
          .padding(.horizontal, 16)
          .padding(.vertical, 12)

        Divider()
          .padding(.leading, 44)

        DeveloperInviteCompactPickerRow(title: "Access", iconName: "key") {
          Picker("Access", selection: $state.role) {
            ForEach(DeveloperInviteRole.allCases) { role in
              Text(verbatim: role.title)
                .tag(role)
            }
          }
          .labelsHidden()
          .frame(width: 120)
        }

        if state.role == .member {
          Divider()
            .padding(.leading, 44)

          Toggle("All public chats", isOn: $state.canAccessPublicChats)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
      }
      .background(Color(nsColor: .controlBackgroundColor))

      Divider()

      HStack(spacing: 12) {
        Text("Private chats are added separately.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
        DeveloperInvitePrimaryButton(state: state, width: 126)
      }
      .padding(16)
    }
    .frame(maxWidth: 480)
    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    .overlay {
      RoundedRectangle(cornerRadius: 14)
        .stroke(Color(nsColor: .separatorColor).opacity(0.8), lineWidth: 0.5)
    }
    .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
  }
}

private struct DeveloperInviteHeroHeader: View {
  let centered: Bool

  var body: some View {
    VStack(alignment: centered ? .center : .leading, spacing: 10) {
      DeveloperInviteWorkspaceMark(size: 56)

      VStack(alignment: centered ? .center : .leading, spacing: 4) {
        Text("Invite to Acme Design")
          .font(.title2.weight(.semibold))
        Text("Invite someone to collaborate with your team. You can adjust their access now or later.")
          .foregroundStyle(.secondary)
          .multilineTextAlignment(centered ? .center : .leading)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
  }
}

private struct DeveloperInviteWorkspaceMark: View {
  let size: CGFloat

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.28)
        .fill(
          LinearGradient(
            colors: [Color.accentColor, Color.accentColor.opacity(0.72)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
      Image(systemName: "bubble.left.and.bubble.right.fill")
        .font(.system(size: size * 0.42, weight: .semibold))
        .foregroundStyle(.white)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

private struct DeveloperInviteMethodPicker: View {
  @Binding var method: DeveloperInviteMethod

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text("Invite via")
        .font(.subheadline.weight(.medium))

      Picker("Invite via", selection: $method) {
        ForEach(DeveloperInviteMethod.allCases) { method in
          Text(verbatim: method.title)
            .tag(method)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct DeveloperInviteInput: View {
  @Binding var state: DeveloperInvitePreviewState
  var compact = false

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: state.method.iconName)
        .foregroundStyle(.secondary)
        .frame(width: 18)

      Group {
        switch state.method {
        case .username:
          TextField("Search by username", text: $state.username)
        case .email:
          TextField("Email address", text: $state.email)
        case .phone:
          TextField("Phone number", text: $state.phone)
        }
      }
      .textFieldStyle(.plain)

      if !compact {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.tertiary)
          .opacity(state.method == .username ? 1 : 0)
      }
    }
    .padding(.horizontal, compact ? 0 : 12)
    .frame(minHeight: compact ? 24 : 38)
    .background(
      compact ? Color.clear : Color(nsColor: .textBackgroundColor),
      in: RoundedRectangle(cornerRadius: 8)
    )
    .overlay {
      if !compact {
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color(nsColor: .separatorColor).opacity(0.8), lineWidth: 0.5)
      }
    }
  }
}

private struct DeveloperInviteAccessControls: View {
  @Binding var state: DeveloperInvitePreviewState
  let compact: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 9 : 12) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Access")
            .font(.subheadline.weight(.medium))
          if !compact {
            Text("Choose what they can do in this workspace.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Picker("Access", selection: $state.role) {
          ForEach(DeveloperInviteRole.allCases) { role in
            Text(verbatim: role.title)
              .tag(role)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 110)
      }

      if state.role == .member {
        Toggle("Can access all public chats", isOn: $state.canAccessPublicChats)
          .font(.subheadline)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct DeveloperInvitePrimaryButton: View {
  let state: DeveloperInvitePreviewState
  var width: CGFloat?

  var body: some View {
    Button(action: {}, label: {
      Label(buttonTitle, systemImage: "paperplane.fill")
        .frame(maxWidth: width == nil ? .infinity : nil)
        .frame(width: width)
    })
    .buttonStyle(.borderedProminent)
    .controlSize(.large)
    .disabled(state.method == .username && state.selectedUserID == nil)
  }

  private var buttonTitle: String {
    switch state.method {
    case .username: "Send invite"
    case .email: "Email invite"
    case .phone: "Create invite"
    }
  }
}

private enum DeveloperInviteResultsPresentation {
  case rows
  case compact
}

private struct DeveloperInviteResults: View {
  @Binding var state: DeveloperInvitePreviewState
  let presentation: DeveloperInviteResultsPresentation

  private let people = [
    DeveloperInvitePerson(id: 201, firstName: "Alex", lastName: "Morgan", username: "alex"),
    DeveloperInvitePerson(id: 202, firstName: "Alexandra", lastName: "Chen", username: "alexandra"),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("People on Inline")
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)

      ForEach(people) { person in
        DeveloperInvitePersonRow(
          person: person,
          selected: state.selectedUserID == person.id,
          compact: presentation == .compact
        ) {
          state.selectedUserID = person.id
        }
      }
    }
  }
}

private struct DeveloperInviteDestinationPanel: View {
  @Binding var state: DeveloperInvitePreviewState

  var body: some View {
    Group {
      if state.method == .username {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 240), spacing: 10)],
          alignment: .leading,
          spacing: 10
        ) {
          DeveloperInviteResults(state: $state, presentation: .rows)
        }
      } else {
        HStack(spacing: 12) {
          Image(systemName: state.method == .email ? "envelope.badge" : "message.badge")
            .font(.title2)
            .foregroundStyle(.tint)
          VStack(alignment: .leading, spacing: 2) {
            Text(state.method == .email ? "Email invitation ready" : "Phone invitation ready")
              .font(.subheadline.weight(.medium))
            Text(
              state.method == .email
                ? "They will receive a direct invitation to Acme Design."
                : "Create the invite, then share it in your preferred messaging app."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
        .padding(18)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
      }
    }
  }
}

private struct DeveloperInvitePerson: Identifiable {
  let id: Int64
  let firstName: String
  let lastName: String
  let username: String
}

private struct DeveloperInvitePersonRow: View {
  let person: DeveloperInvitePerson
  let selected: Bool
  let compact: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        UserAvatar(
          userID: person.id,
          firstName: person.firstName,
          lastName: person.lastName,
          email: nil,
          username: person.username,
          stableAvatarIdentity: nil,
          remoteURL: nil,
          localURL: nil,
          size: compact ? 28 : 34,
          cacheRemoteAvatar: false
        )

        VStack(alignment: .leading, spacing: 1) {
          Text("\(person.firstName) \(person.lastName)")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
          Text("@\(person.username)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(selected ? Color.accentColor : Color.secondary)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(compact ? 6 : 9)
    .background(
      selected ? Color.accentColor.opacity(0.09) : Color.clear,
      in: RoundedRectangle(cornerRadius: 8)
    )
  }
}

private struct DeveloperInviteContextRow: View {
  let iconName: String
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: iconName)
        .foregroundStyle(.tint)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.subheadline.weight(.medium))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

private struct DeveloperInviteStepCard<Content: View>: View {
  let number: Int
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    DeveloperInviteCard {
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 8) {
          Text("\(number)")
            .font(.caption.bold().monospacedDigit())
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Color.accentColor, in: Circle())
          Text(title)
            .font(.headline)
        }

        content
      }
    }
    .frame(maxWidth: .infinity, alignment: .top)
  }
}

private struct DeveloperInviteSummary: View {
  let state: DeveloperInvitePreviewState

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      DeveloperInviteSummaryRow(title: "Workspace", value: "Acme Design")
      DeveloperInviteSummaryRow(title: "Recipient", value: recipient)
      DeveloperInviteSummaryRow(title: "Access", value: access)
    }
  }

  private var recipient: String {
    switch state.method {
    case .username: "Alex Morgan"
    case .email: state.email
    case .phone: state.phone
    }
  }

  private var access: String {
    if state.role == .admin {
      return "Admin"
    }
    return state.canAccessPublicChats ? "Member · all public chats" : "Member · invited chats only"
  }
}

private struct DeveloperInviteSummaryRow: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.subheadline.weight(.medium))
        .lineLimit(2)
    }
  }
}

private struct DeveloperInviteCompactPickerRow<Content: View>: View {
  let title: String
  let iconName: String
  @ViewBuilder let content: Content

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: iconName)
        .foregroundStyle(.secondary)
        .frame(width: 18)
      Text(title)
        .frame(maxWidth: .infinity, alignment: .leading)
      content
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }
}

private struct DeveloperInviteCard<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    content
      .padding(20)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12)
          .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
      }
  }
}

#Preview("Invite layout playground") {
  DeveloperPlaygroundInviteView(selectedLayout: .constant(.focused))
    .frame(width: 900, height: 700)
}
#endif
