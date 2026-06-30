import InlineKit
import InlineUI
import SwiftUI

struct UserGroupsSettingsSection: View {
  @ObservedObject var viewModel: UserGroupsViewModel
  let canManage: Bool

  @State private var isCreating = false
  @State private var editingGroup: UserGroup?

  var body: some View {
    Section("User Groups") {
      if viewModel.isLoading, viewModel.groups.isEmpty {
        HStack {
          ProgressView()
          Text("Loading groups...")
            .foregroundStyle(.secondary)
        }
      } else if viewModel.groups.isEmpty {
        Text(canManage ? "No user groups yet" : "No groups available")
          .foregroundStyle(.secondary)
      } else {
        ForEach(viewModel.groups) { group in
          Button {
            guard canManage else { return }
            editingGroup = group
          } label: {
            UserGroupSettingsRow(
              group: group,
              members: viewModel.groupMembersByGroupId[group.id, default: []],
              showsDisclosure: canManage
            )
          }
          .buttonStyle(.plain)
          .disabled(!canManage)
        }
      }

      if canManage {
        Button {
          isCreating = true
        } label: {
          Label("Create User Group", systemImage: "person.3.sequence.fill")
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
      NavigationView {
        UserGroupEditorView(
          viewModel: viewModel,
          group: nil,
          onDone: { isCreating = false },
          onCancel: { isCreating = false }
        )
      }
    }
    .sheet(item: $editingGroup) { group in
      NavigationView {
        UserGroupEditorView(
          viewModel: viewModel,
          group: group,
          onDone: { editingGroup = nil },
          onCancel: { editingGroup = nil }
        )
      }
    }
  }
}

private struct UserGroupSettingsRow: View {
  let group: UserGroup
  let members: [UserGroupMemberInfo]
  let showsDisclosure: Bool

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "person.3.fill")
        .font(.callout.weight(.semibold))
        .foregroundStyle(.white)
        .frame(width: 30, height: 30)
        .background(Color.accentColor)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

      VStack(alignment: .leading, spacing: 3) {
        Text(group.name)
          .font(.body)
          .foregroundStyle(.primary)
          .lineLimit(1)

        Text(subtitle)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Spacer()

      if showsDisclosure {
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, 2)
  }

  private var subtitle: String {
    let count = group.memberCount == 1 ? "1 person" : "\(group.memberCount) people"
    guard let description = group.description, !description.isEmpty else {
      return count
    }
    return "\(description) - \(count)"
  }
}

private struct UserGroupEditorView: View {
  @ObservedObject var viewModel: UserGroupsViewModel
  let group: UserGroup?
  let onDone: () -> Void
  let onCancel: () -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var description: String
  @State private var selectedUserIds: Set<Int64>
  @State private var showDeleteConfirm = false
  @State private var localError: String?

  init(
    viewModel: UserGroupsViewModel,
    group: UserGroup?,
    onDone: @escaping () -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.viewModel = viewModel
    self.group = group
    self.onDone = onDone
    self.onCancel = onCancel
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
    Form {
      Section {
        TextField("Name", text: $name)
          .textInputAutocapitalization(.words)

        TextField("Description", text: $description, axis: .vertical)
          .lineLimit(2 ... 4)
      } footer: {
        Text("Groups appear in @ mentions and can be granted access to private threads.")
      }

      Section(
        header: Text("Members"),
        footer: Text("\(selectedUserIds.count)/\(UserGroupsViewModel.maxMembers) people selected")
      ) {
        ForEach(viewModel.selectableMembers) { member in
          Button {
            toggle(member.userInfo.user.id)
          } label: {
            HStack(spacing: 10) {
              UserAvatar(userInfo: member.userInfo, size: 30)

              VStack(alignment: .leading, spacing: 2) {
                Text(member.userInfo.user.displayName)
                  .foregroundStyle(.primary)
                if let username = member.userInfo.user.username, !username.isEmpty {
                  Text("@\(username)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
              }

              Spacer()

              if selectedUserIds.contains(member.userInfo.user.id) {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundStyle(.tint)
              }
            }
          }
          .buttonStyle(.plain)
        }
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
          Button(role: .destructive) {
            showDeleteConfirm = true
          } label: {
            Label("Delete User Group", systemImage: "trash")
          }
          .disabled(viewModel.isMutating)
        }
      }
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") {
          onCancel()
          dismiss()
        }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button(viewModel.isMutating ? "Saving..." : "Save") {
          save()
        }
        .disabled(!canSave)
      }
    }
    .alert("Delete User Group?", isPresented: $showDeleteConfirm) {
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
          try await viewModel.update(
            group: group,
            name: name,
            description: description,
            userIds: selectedUserIds
          )
        } else {
          try await viewModel.create(
            name: name,
            description: description,
            userIds: selectedUserIds
          )
        }
        onDone()
        dismiss()
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
        onDone()
        dismiss()
      } catch {
        localError = error.localizedDescription
      }
    }
  }
}
