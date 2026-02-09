import InlineKit
import InlineUI
import SwiftUI

struct AddHomeParticipantsSheet: View {
  @StateObject private var viewModel: AddHomeParticipantsViewModel
  @Binding var isPresented: Bool

  init(
    chatId: Int64,
    currentUserId: Int64?,
    currentParticipants: [UserInfo],
    db: AppDatabase,
    isPresented: Binding<Bool>
  ) {
    _viewModel = StateObject(
      wrappedValue: AddHomeParticipantsViewModel(
        chatId: chatId,
        currentUserId: currentUserId,
        currentParticipants: currentParticipants,
        db: db
      )
    )
    _isPresented = isPresented
  }

  var body: some View {
    VStack(spacing: 0) {
      header

      Divider()

      searchField
        .padding(.horizontal, 16)
        .padding(.vertical, 12)

      if viewModel.isLoading && viewModel.displayUsers.isEmpty {
        loadingView
      } else if let error = viewModel.errorMessage {
        errorView(error)
      } else if viewModel.filteredUsers.isEmpty {
        emptyView
      } else {
        usersList
      }

      Divider()

      footer
    }
    .frame(width: 420, height: 520)
    .task {
      await viewModel.loadSuggestedUsers()
    }
    .onChange(of: viewModel.searchText) { _ in
      viewModel.search()
    }
  }

  private var header: some View {
    HStack {
      Text("Add Participants")
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

      TextField("Search by name, username, or email...", text: $viewModel.searchText)
        .textFieldStyle(.plain)
        .font(.system(size: 13))
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(Color.gray.opacity(0.1))
    .cornerRadius(6)
  }

  private var usersList: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(viewModel.filteredUsers, id: \.id) { userInfo in
          UserRow(
            userInfo: userInfo,
            isSelected: viewModel.selectedUserIds.contains(userInfo.user.id),
            onTap: { viewModel.toggleSelection(userId: userInfo.user.id) }
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
      Text("Loading...")
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
      Text("Failed to search")
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
      Text(viewModel.searchText.isEmpty ? "No suggested people" : "No results found")
        .font(.system(size: 13, weight: .medium))
      if viewModel.searchText.count > 0 && viewModel.searchText.count < 2 {
        Text("Type at least 2 characters to search")
          .font(.system(size: 11))
          .foregroundColor(.secondary)
      } else if !viewModel.searchText.isEmpty {
        Text("Try a different keyword")
          .font(.system(size: 11))
          .foregroundColor(.secondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var footer: some View {
    HStack {
      if !viewModel.selectedUserIds.isEmpty {
        Text("\(viewModel.selectedUserIds.count) selected")
          .font(.system(size: 12))
          .foregroundColor(.secondary)
      }

      Spacer()

      Button("Cancel") { isPresented = false }
        .buttonStyle(.plain)

      Button("Add") {
        Task {
          do {
            try await viewModel.addSelectedParticipants()
            isPresented = false
          } catch {
          }
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(!viewModel.canAddParticipants)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }
}

private struct UserRow: View {
  let userInfo: UserInfo
  let isSelected: Bool
  let onTap: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      UserAvatar(user: userInfo.user, size: 32)

      VStack(alignment: .leading, spacing: 2) {
        Text(displayName)
          .font(.system(size: 13, weight: .medium))

        if let username = userInfo.user.username {
          Text("@\(username)")
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        } else if let email = userInfo.user.email {
          Text(email)
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
    let name = "\(userInfo.user.firstName ?? "") \(userInfo.user.lastName ?? "")"
      .trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? (userInfo.user.username ?? userInfo.user.email ?? "Unknown") : name
  }
}

