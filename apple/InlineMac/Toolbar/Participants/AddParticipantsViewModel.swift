import Combine
import InlineKit
import Logger
import SwiftUI

@MainActor
final class AddParticipantsViewModel: ObservableObject {
  @Published private(set) var availableMembers: [FullMemberItem] = []
  @Published private(set) var isLoading = true
  @Published private(set) var errorMessage: String?
  @Published var searchText = ""
  @Published var selectedUserIds: Set<Int64> = []

  private let chatId: Int64
  private let spaceId: Int64
  private let currentParticipantIds: Set<Int64>
  private let spaceViewModel: SpaceFullMembersViewModel
  private let db: AppDatabase
  private var cancellables = Set<AnyCancellable>()

  var filteredMembers: [FullMemberItem] {
    let members = availableMembers.filter { member in
      !currentParticipantIds.contains(member.userInfo.user.id)
    }

    if searchText.isEmpty {
      return members
    }

    return members.filter { member in
      let name = "\(member.userInfo.user.firstName ?? "") \(member.userInfo.user.lastName ?? "")".trimmingCharacters(in: .whitespaces)
      let username = member.userInfo.user.username ?? ""
      let email = member.userInfo.user.email ?? ""

      return name.localizedCaseInsensitiveContains(searchText) ||
             username.localizedCaseInsensitiveContains(searchText) ||
             email.localizedCaseInsensitiveContains(searchText)
    }
  }

  var canAddParticipants: Bool {
    !selectedUserIds.isEmpty && !isLoading
  }

  init(chatId: Int64, spaceId: Int64, currentParticipants: [UserInfo], db: AppDatabase) {
    self.chatId = chatId
    self.spaceId = spaceId
    self.currentParticipantIds = Set(currentParticipants.map { $0.user.id })
    self.db = db
    self.spaceViewModel = SpaceFullMembersViewModel(db: db, spaceId: spaceId)

    availableMembers = spaceViewModel.members
    isLoading = spaceViewModel.isLoading
    errorMessage = spaceViewModel.errorMessage

    observeSpaceMembers()
  }

  private func observeSpaceMembers() {
    spaceViewModel.$members
      .receive(on: DispatchQueue.main)
      .sink { [weak self] members in
        self?.availableMembers = members
      }
      .store(in: &cancellables)

    spaceViewModel.$isLoading
      .receive(on: DispatchQueue.main)
      .sink { [weak self] loading in
        self?.isLoading = loading
      }
      .store(in: &cancellables)

    spaceViewModel.$errorMessage
      .receive(on: DispatchQueue.main)
      .sink { [weak self] error in
        self?.errorMessage = error
      }
      .store(in: &cancellables)
  }

  func loadMembers() async {
    await spaceViewModel.refetchMembers()
  }

  func toggleSelection(userId: Int64) {
    if selectedUserIds.contains(userId) {
      selectedUserIds.remove(userId)
    } else {
      selectedUserIds.insert(userId)
    }
  }

  func addSelectedParticipants() async throws {
    isLoading = true
    errorMessage = nil

    do {
      for userId in selectedUserIds {
        try await Api.realtime.send(.addChatParticipant(
          chatID: chatId,
          userID: userId
        ))
      }

      selectedUserIds.removeAll()
      isLoading = false
    } catch {
      isLoading = false
      errorMessage = error.localizedDescription
      Log.shared.error("Failed to add participants", error: error)
      throw error
    }
  }
}
