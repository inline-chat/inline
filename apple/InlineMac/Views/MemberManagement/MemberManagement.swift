import AppKit
import InlineKit
import InlineUI
import SwiftUI

public struct MemberManagementView: View {
  @EnvironmentObject var nav: Nav

  @StateObject private var membersViewModel: SpaceFullMembersViewModel
  @StateObject private var membershipStatusViewModel: SpaceMembershipStatusViewModel
  @StateObject private var memberActionsViewModel: SpaceMemberActionsViewModel

  @State private var errorMessage: String?
  @State private var accessPopoverMemberId: Int64?
  @State private var filterText: String = ""

  private let spaceId: Int64

  private var displayedMembers: [FullMemberItem] {
    filteredMembers.sorted { lhs, rhs in
      let lhsIsCurrent = lhs.userInfo.user.isCurrentUser()
      let rhsIsCurrent = rhs.userInfo.user.isCurrentUser()

      if lhsIsCurrent, !rhsIsCurrent { return true }
      if rhsIsCurrent, !lhsIsCurrent { return false }

      return lhs.member.date < rhs.member.date
    }
  }

  private var filteredMembers: [FullMemberItem] {
    let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return membersViewModel.members }

    return membersViewModel.members.filter { member in
      let user = member.userInfo.user
      return contains(query, in: user.displayName)
        || contains(query, in: user.email)
        || contains(query, in: user.username)
    }
  }

  private var inlineStaffCount: Int {
    displayedMembers.count(where: { member in
      member.userInfo.user.email?.lowercased().hasSuffix("@inline.chat") == true
    })
  }

  private var memberCountExcludingStaff: Int {
    max(0, displayedMembers.count - inlineStaffCount)
  }

  private static let joinedFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
  }()

  public init(spaceId: Int64) {
    self.spaceId = spaceId
    _membersViewModel = StateObject(wrappedValue: SpaceFullMembersViewModel(db: AppDatabase.shared, spaceId: spaceId))
    _membershipStatusViewModel = StateObject(
      wrappedValue: SpaceMembershipStatusViewModel(db: AppDatabase.shared, spaceId: spaceId)
    )
    _memberActionsViewModel = StateObject(wrappedValue: SpaceMemberActionsViewModel(spaceId: spaceId))
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      if let errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
          .font(.callout)
      }

      memberTable
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(16)
    .navigationTitle("Manage Members")
    .task {
      await membershipStatusViewModel.refreshIfNeeded()
      await membersViewModel.refetchMembers()
    }
    .alert(
      "Error",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { presented in
          if presented == false {
            errorMessage = nil
          }
        }
      )
    ) {
      Button("OK", role: .cancel) {
        errorMessage = nil
      }
    } message: {
      if let errorMessage {
        Text(errorMessage)
      }
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      if let space = membersViewModel.space {
        SpaceAvatar(space: space, size: 28)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(membersViewModel.space?.displayName ?? "Space")
          .font(.headline)

        let total = memberCountExcludingStaff
        let inlineCount = inlineStaffCount
        let base = "\(total) member\(total == 1 ? "" : "s")"
        let detail = inlineCount > 0 ? " (and \(inlineCount) Inline staff)" : ""

        Text(base + detail)
          .foregroundStyle(.secondary)
          .font(.subheadline)
      }

      Spacer()

      HStack(spacing: 8) {
        TextField("Filter…", text: $filterText)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 180)

        Button {
          nav.open(.inviteToSpace(spaceId: spaceId))
        } label: {
          Label("Invite", systemImage: "person.badge.plus")
        }
      }
    }
  }

  @ViewBuilder
  private var memberTable: some View {
    if displayedMembers.isEmpty {
      VStack(spacing: 8) {
        if membersViewModel.isLoading {
          ProgressView()
          Text("Fetching members…")
            .foregroundStyle(.secondary)
        } else {
          Text("No members found")
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    } else {
      Table(displayedMembers) {
        TableColumn("Member") { member in
          memberIdentity(member)
        }

        TableColumn("Joined") { member in
          Text(joinedDate(member))
            .foregroundStyle(.secondary)
        }

        TableColumn("Role") { member in
          HStack(spacing: 6) {
            Text(roleLabel(member))
              .fontWeight(.medium)
              .foregroundStyle(.secondary)

            if isRestricted(member) {
              restrictedInfoButton(for: member)
            }
          }
        }

        if membershipStatusViewModel.canManageMembers {
          TableColumn("Actions") { member in
            HStack {
              Spacer()
              if !member.userInfo.user.isCurrentUser() {
                actionMenu(for: member)
              }
            }
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .tableStyle(.inset(alternatesRowBackgrounds: false))
    }
  }

  private func memberIdentity(_ member: FullMemberItem) -> some View {
    HStack(spacing: 10) {
      UserAvatar(userInfo: member.userInfo, size: 32)

      VStack(alignment: .leading, spacing: 2) {
        let isCurrentUser = member.userInfo.user.isCurrentUser()
        HStack(spacing: 6) {
          Text(member.userInfo.user.displayName + (isCurrentUser ? " (You)" : ""))
            .font(.body)
            .lineLimit(1)
            .truncationMode(.tail)

          if isInlineStaff(member.userInfo.user) {
            inlineStaffBadge
          }

          if member.userInfo.user.pendingSetup == true {
            pendingInviteBadge
          }
        }

        HStack(spacing: 6) {
          Text(contactDetail(for: member.userInfo.user))
            .foregroundStyle(.secondary)
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
    }
    .padding(.vertical, 4)
  }

  private func joinedDate(_ member: FullMemberItem) -> String {
    MemberManagementView.joinedFormatter.string(from: member.member.date)
  }

  private func roleLabel(_ member: FullMemberItem) -> String {
    switch member.member.role {
      case .owner: "Owner"
      case .admin: "Admin"
      case .member: "Member"
    }
  }

  private func contactDetail(for user: User) -> String {
    if let email = user.email, !email.isEmpty {
      return email
    }

    if let phone = user.phoneNumber, !phone.isEmpty {
      return phone
    }

    if let username = user.username, !username.isEmpty {
      return username
    }

    return "No contact info"
  }

  private func contains(_ query: String, in value: String?) -> Bool {
    guard let value else { return false }
    return value.lowercased().contains(query)
  }

  private var pendingInviteBadge: some View {
    Text("Invited")
      .font(.caption2)
      .fontWeight(.semibold)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(
        Capsule()
          .fill(Color.green.opacity(0.18))
      )
      .foregroundStyle(Color.green)
  }

  private var inlineStaffBadge: some View {
    Text("Inline Staff")
      .font(.caption2)
      .fontWeight(.semibold)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(
        Capsule()
          .fill(Color.blue.opacity(0.18))
      )
      .foregroundStyle(Color.blue)
  }

  private func isInlineStaff(_ user: User) -> Bool {
    user.email?.lowercased().hasSuffix("@inline.chat") == true
  }

  private func isRestricted(_ member: FullMemberItem) -> Bool {
    member.member.role == .member && member.member.canAccessPublicChats == false
  }

  private func restrictedInfoButton(for member: FullMemberItem) -> some View {
    Button {
      if accessPopoverMemberId == member.id {
        accessPopoverMemberId = nil
      } else {
        accessPopoverMemberId = member.id
      }
    } label: {
      Image(systemName: "exclamationmark.lock.fill")
        .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
    .popover(
      isPresented: Binding(
        get: { accessPopoverMemberId == member.id },
        set: { open in
          accessPopoverMemberId = open ? member.id : nil
        }
      )
    ) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Restricted access")
          .font(.headline)
        Text("This member can only see the private threads they are explicitly added to.")
          .lineLimit(3)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .padding()
      .frame(width: 280)
    }
  }

  private func actionMenu(for member: FullMemberItem) -> some View {
    let userId = member.userInfo.user.id
    let isDeleting = memberActionsViewModel.isDeleting(userId: userId)

    return Menu {
      Button("Delete", systemImage: "trash", role: .destructive) {
        Task {
          await confirmAndDelete(member: member)
        }
      }
      .disabled(!canDelete(member: member) || isDeleting)
    } label: {
      if isDeleting {
        ProgressView()
          .controlSize(.small)
      } else {
        Image(systemName: "ellipsis.circle")
      }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  private func canDelete(member: FullMemberItem) -> Bool {
    guard membershipStatusViewModel.canManageMembers else { return false }
    if member.member.role == .owner { return false }
    if member.userInfo.user.isCurrentUser() { return false }
    return true
  }

  private func confirmAndDelete(member: FullMemberItem) async {
    guard canDelete(member: member) else { return }

    let confirmed = await MainActor.run { () -> Bool in
      let alert = NSAlert()
      alert.messageText = "Remove \(member.userInfo.user.displayName)?"
      alert.informativeText = "They will lose access to this space and its chats."
      alert.alertStyle = .warning
      let cancelButton = alert.addButton(withTitle: "Cancel")
      cancelButton.keyEquivalent = "\r"
      let deleteButton = alert.addButton(withTitle: "Delete")
      deleteButton.hasDestructiveAction = true
      deleteButton.keyEquivalent = ""
      return alert.runModal() == .alertSecondButtonReturn
    }

    guard confirmed else { return }

    do {
      try await memberActionsViewModel.deleteMember(userId: member.userInfo.user.id)
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

#Preview {
  MemberManagementView(spaceId: 1)
    .previewsEnvironment(.empty)
}
