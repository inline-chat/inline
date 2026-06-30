import InlineKit
import InlineUI
import SwiftUI

struct UserGroupsSettingsView: View {
  @ObservedObject var viewModel: UserGroupsViewModel
  let canManage: Bool

  @State private var isCreating = false
  @State private var editingGroup: UserGroup?

  var body: some View {
    Section("User Groups") {
      if viewModel.isLoading, viewModel.groups.isEmpty {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Loading groups...")
            .foregroundStyle(.secondary)
        }
      } else if viewModel.groups.isEmpty {
        Text(canManage ? "No user groups yet." : "No groups available.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(viewModel.groups) { group in
          HStack {
            UserGroupSettingsRow(
              group: group,
              members: viewModel.groupMembersByGroupId[group.id, default: []]
            )

            Spacer(minLength: 12)

            if canManage {
              Button("Edit...") {
                editingGroup = group
              }
              .controlSize(.small)
            }
          }
        }
      }

      if canManage {
        Button {
          isCreating = true
        } label: {
          Label("Create User Group...", systemImage: "person.3.sequence.fill")
        }
        .disabled(viewModel.isMutating)
      }

      if let error = viewModel.errorMessage {
        Text(error)
          .font(.footnote)
          .foregroundStyle(.red)
      }
    }
    .task {
      await viewModel.loadIfNeeded()
    }
    .sheet(isPresented: $isCreating) {
      UserGroupEditorSheet(
        viewModel: viewModel,
        group: nil,
        onClose: { isCreating = false }
      )
    }
    .sheet(item: $editingGroup) { group in
      UserGroupEditorSheet(
        viewModel: viewModel,
        group: group,
        onClose: { editingGroup = nil }
      )
    }
  }
}

private struct UserGroupSettingsRow: View {
  let group: UserGroup
  let members: [UserGroupMemberInfo]

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "person.3.fill")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 30, height: 30)
        .background(Color.accentColor)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

      VStack(alignment: .leading, spacing: 2) {
        Text(group.name)
          .font(.body)
          .lineLimit(1)

        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(.vertical, 3)
  }

  private var subtitle: String {
    let count = group.memberCount == 1 ? "1 person" : "\(group.memberCount) people"
    guard let description = group.description, !description.isEmpty else {
      return count
    }
    return "\(description) - \(count)"
  }
}

private struct UserGroupEditorSheet: View {
  @ObservedObject var viewModel: UserGroupsViewModel
  let group: UserGroup?
  let onClose: () -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var description: String
  @State private var selectedUserIds: Set<Int64>
  @State private var localError: String?
  @State private var showDeleteConfirm = false

  init(viewModel: UserGroupsViewModel, group: UserGroup?, onClose: @escaping () -> Void) {
    self.viewModel = viewModel
    self.group = group
    self.onClose = onClose
    _name = State(initialValue: group?.name ?? "")
    _description = State(initialValue: group?.description ?? "")
    if let group {
      _selectedUserIds = State(initialValue: viewModel.userIds(for: group))
    } else {
      _selectedUserIds = State(initialValue: [])
    }
  }

  private var title: String {
    group == nil ? "New User Group" : "Edit User Group"
  }

  private var canSave: Bool {
    !viewModel.isMutating &&
      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
      !selectedUserIds.isEmpty &&
      selectedUserIds.count <= UserGroupsViewModel.maxMembers
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(title)
          .font(.headline)
        Spacer()
        Button {
          close()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(.cancelAction)
      }
      .padding(16)

      Divider()

      Form {
        Section("Details") {
          TextField("Name", text: $name)
          TextField("Description", text: $description, axis: .vertical)
            .lineLimit(2 ... 4)
          Text("Groups appear in @ mentions and can be granted access to private threads.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        Section("Members") {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(viewModel.selectableMembers) { member in
                MemberSelectionRow(
                  member: member,
                  isSelected: selectedUserIds.contains(member.userInfo.user.id),
                  onToggle: {
                    toggle(member.userInfo.user.id)
                  }
                )
              }
            }
          }
          .frame(minHeight: 260)

          Text("\(selectedUserIds.count)/\(UserGroupsViewModel.maxMembers) people selected")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        if let message = localError ?? viewModel.errorMessage {
          Section {
            Text(message)
              .font(.footnote)
              .foregroundStyle(.red)
          }
        }

        if group != nil {
          Section {
            Button("Delete User Group...", role: .destructive) {
              showDeleteConfirm = true
            }
            .disabled(viewModel.isMutating)
          }
        }
      }
      .formStyle(.grouped)

      Divider()

      HStack {
        Spacer()
        Button("Cancel") {
          close()
        }
        .keyboardShortcut(.cancelAction)

        Button(viewModel.isMutating ? "Saving..." : "Save") {
          save()
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(!canSave)
      }
      .padding(16)
    }
    .frame(width: 520, height: 640)
    .confirmationDialog(
      "Delete User Group?",
      isPresented: $showDeleteConfirm,
      titleVisibility: .visible
    ) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) {
        delete()
      }
    } message: {
      Text("Deletion is only allowed when no private thread grants access through this group. If a thread uses it, nothing changes and Inline will show an error.")
    }
  }

  private func toggle(_ userId: Int64) {
    localError = nil
    if selectedUserIds.contains(userId) {
      selectedUserIds.remove(userId)
      return
    }

    guard selectedUserIds.count < UserGroupsViewModel.maxMembers else {
      localError = "User groups can include up to \(UserGroupsViewModel.maxMembers) people."
      return
    }

    selectedUserIds.insert(userId)
  }

  private func save() {
    Task {
      do {
        if let group {
          try await viewModel.update(group: group, name: name, description: description, userIds: selectedUserIds)
        } else {
          try await viewModel.create(name: name, description: description, userIds: selectedUserIds)
        }
        close()
      } catch {
        localError = error.localizedDescription
      }
    }
  }

  private func delete() {
    guard let group else { return }

    Task {
      do {
        try await viewModel.delete(group: group)
        close()
      } catch {
        localError = error.localizedDescription
      }
    }
  }

  private func close() {
    onClose()
    dismiss()
  }
}

private struct MemberSelectionRow: View {
  let member: FullMemberItem
  let isSelected: Bool
  let onToggle: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      UserAvatar(user: member.userInfo.user, size: 28)

      VStack(alignment: .leading, spacing: 1) {
        Text(member.userInfo.user.displayName)
        if let username = member.userInfo.user.username, !username.isEmpty {
          Text("@\(username)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Spacer()

      Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.45))
    }
    .padding(.vertical, 6)
    .contentShape(Rectangle())
    .onTapGesture(perform: onToggle)
  }
}
