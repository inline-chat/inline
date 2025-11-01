import InlineKit
import InlineUI
import SwiftUI

struct SelectParticipantsSheet: View {
  @StateObject private var viewModel: SelectParticipantsViewModel
  @Binding var selectedUserIds: Set<Int64>
  @Binding var isPresented: Bool

  init(
    spaceId: Int64,
    selectedUserIds: Binding<Set<Int64>>,
    db: AppDatabase,
    isPresented: Binding<Bool>
  ) {
    _viewModel = StateObject(
      wrappedValue: SelectParticipantsViewModel(
        spaceId: spaceId,
        db: db
      )
    )
    _selectedUserIds = selectedUserIds
    _isPresented = isPresented
  }

  var body: some View {
    VStack(spacing: 0) {
      header

      Divider()

      searchField
        .padding(.horizontal, 16)
        .padding(.vertical, 12)

      if viewModel.isLoading && viewModel.availableMembers.isEmpty {
        loadingView
      } else if let error = viewModel.errorMessage {
        errorView(error)
      } else if viewModel.filteredMembers.isEmpty {
        emptyView
      } else {
        membersList
      }

      Divider()

      footer
    }
    .frame(width: 400, height: 500)
    .task {
      await viewModel.loadMembers()
    }
  }

  private var header: some View {
    HStack {
      Text("Select Participants")
        .font(.system(size: 14, weight: .semibold))

      Spacer()

      Button(action: { isPresented = false }) {
        Image(systemName: "xmark")
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(.secondary)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private var searchField: some View {
    HStack {
      Image(systemName: "magnifyingglass")
        .foregroundColor(.secondary)
        .font(.system(size: 12))

      TextField("Search by name or username...", text: $viewModel.searchText)
        .textFieldStyle(.plain)
        .font(.system(size: 13))
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(Color.gray.opacity(0.1))
    .cornerRadius(6)
  }

  private var membersList: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(viewModel.filteredMembers, id: \.userInfo.user.id) { member in
          MemberRow(
            member: member,
            isSelected: selectedUserIds.contains(member.userInfo.user.id),
            onTap: {
              let userId = member.userInfo.user.id
              if selectedUserIds.contains(userId) {
                selectedUserIds.remove(userId)
              } else {
                selectedUserIds.insert(userId)
              }
            }
          )
        }
      }
      .padding(.horizontal, 16)
    }
  }

  private var loadingView: some View {
    VStack(spacing: 12) {
      ProgressView()
        .scaleEffect(0.8)
      Text("Loading members...")
        .font(.system(size: 12))
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func errorView(_ error: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 32))
        .foregroundColor(.orange)
      Text("Failed to load members")
        .font(.system(size: 13, weight: .medium))
      Text(error)
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyView: some View {
    VStack(spacing: 12) {
      Image(systemName: viewModel.searchText.isEmpty ? "person.3" : "magnifyingglass")
        .font(.system(size: 32))
        .foregroundColor(.secondary)
      Text(viewModel.searchText.isEmpty ? "No available members" : "No results found")
        .font(.system(size: 13, weight: .medium))
      if !viewModel.searchText.isEmpty {
        Text("Try searching with a different keyword")
          .font(.system(size: 11))
          .foregroundColor(.secondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var footer: some View {
    HStack {
      if !selectedUserIds.isEmpty {
        Text("\(selectedUserIds.count) selected")
          .font(.system(size: 12))
          .foregroundColor(.secondary)
      }

      Spacer()

      Button("Done") {
        isPresented = false
      }
      .buttonStyle(.borderedProminent)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }
}

private struct MemberRow: View {
  let member: FullMemberItem
  let isSelected: Bool
  let onTap: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      UserAvatar(user: member.userInfo.user, size: 32)

      VStack(alignment: .leading, spacing: 2) {
        Text(displayName)
          .font(.system(size: 13, weight: .medium))

        if let username = member.userInfo.user.username {
          Text("@\(username)")
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        }
      }

      Spacer()

      if isSelected {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 18))
          .foregroundColor(.blue)
      } else {
        Image(systemName: "circle")
          .font(.system(size: 18))
          .foregroundColor(.secondary.opacity(0.3))
      }
    }
    .padding(.vertical, 8)
    .contentShape(Rectangle())
    .onTapGesture(perform: onTap)
  }

  private var displayName: String {
    let name = "\(member.userInfo.user.firstName ?? "") \(member.userInfo.user.lastName ?? "")"
      .trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? (member.userInfo.user.username ?? member.userInfo.user.email ?? "Unknown") : name
  }
}
