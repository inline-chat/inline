import InlineKit
import InlineUI
import SwiftUI

struct ChatVisibilityParticipantsSheet: View {
  @ObservedObject var spaceViewModel: SpaceFullMembersViewModel
  @Binding var selectedParticipants: Set<Int64>
  let currentUserId: Int64?
  let onConfirm: () -> Void
  let onCancel: () -> Void

  @State private var searchText = ""

  private var filteredMembers: [FullMemberItem] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if query.isEmpty {
      return spaceViewModel.filteredMembers
    }

    return spaceViewModel.filteredMembers.filter { member in
      let user = member.userInfo.user
      let candidate = [
        user.displayName,
        user.firstName ?? "",
        user.lastName ?? "",
        user.username ?? "",
        user.email ?? "",
      ]
      .map { $0.lowercased() }

      return candidate.contains { $0.contains(query) }
    }
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text("Only selected participants can access this private chat.")
            .font(.footnote)
            .foregroundColor(.secondary)
        }

        if spaceViewModel.isLoading {
          Section {
            HStack {
              Spacer()
              ProgressView()
              Spacer()
            }
          }
        }

        if let errorMessage = spaceViewModel.errorMessage {
          Section {
            Text(errorMessage)
              .foregroundColor(.red)
              .font(.footnote)
          }
        }

        Section {
          ForEach(filteredMembers) { member in
            Button(action: {
              toggleSelection(member)
            }) {
              memberRow(member)
            }
            .buttonStyle(.plain)
            .disabled(isCurrentUser(member))
          }
        }
      }
      .navigationTitle("Select Participants")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $searchText, prompt: "Search members")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel") {
            onCancel()
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Make Private") {
            onConfirm()
          }
          .disabled(selectedParticipants.isEmpty)
        }
      }
      .task {
        await spaceViewModel.refetchMembers()
      }
    }
  }

  private func isCurrentUser(_ member: FullMemberItem) -> Bool {
    guard let currentUserId else { return false }
    return member.userInfo.user.id == currentUserId
  }

  private func toggleSelection(_ member: FullMemberItem) {
    let userId = member.userInfo.user.id
    if isCurrentUser(member) {
      return
    }
    if selectedParticipants.contains(userId) {
      selectedParticipants.remove(userId)
    } else {
      selectedParticipants.insert(userId)
    }
  }

  @ViewBuilder
  private func memberRow(_ member: FullMemberItem) -> some View {
    let userInfo = member.userInfo
    let userId = userInfo.user.id
    let isSelected = selectedParticipants.contains(userId) || isCurrentUser(member)

    HStack(spacing: 12) {
      UserAvatar(userInfo: userInfo, size: 32)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(userInfo.user.displayName)
            .foregroundColor(.primary)

          if isCurrentUser(member) {
            Text("(You)")
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }
        if let username = userInfo.user.username, !username.isEmpty {
          Text("@\(username)")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }

      Spacer()

      Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        .foregroundColor(isSelected ? Color(ThemeManager.shared.selected.accent) : .secondary)
    }
    .contentShape(Rectangle())
  }
}
