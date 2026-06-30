import Combine
import InlineKit
import Logger
import SwiftUI

@MainActor
final class AddParticipantsViewModel: ObservableObject {
  @Published private(set) var availableMembers: [FullMemberItem] = []
  @Published private(set) var availableGroups: [UserGroup] = []
  @Published private(set) var isLoading = true
  @Published private(set) var errorMessage: String?
  @Published var searchText = ""
  @Published var selectedUserIds: Set<Int64> = []
  @Published var selectedGroupIds: Set<Int64> = []

  private let chatId: Int64
  private let spaceId: Int64
  private let currentParticipantIds: Set<Int64>
  private let currentGroupIds: Set<Int64>
  private let spaceViewModel: SpaceFullMembersViewModel
  private let groupsViewModel: UserGroupsViewModel
  private let db: AppDatabase
  private var cancellables = Set<AnyCancellable>()
  private var didRequestMembers = false

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

  var filteredGroups: [UserGroup] {
    let groups = availableGroups.filter { group in
      !currentGroupIds.contains(group.id)
    }

    guard !searchText.isEmpty else { return groups }

    return groups.filter { group in
      group.name.localizedCaseInsensitiveContains(searchText) ||
        (group.description?.localizedCaseInsensitiveContains(searchText) == true)
    }
  }

  var canAddParticipants: Bool {
    (!selectedUserIds.isEmpty || !selectedGroupIds.isEmpty) && !isLoading
  }

  init(
    chatId: Int64,
    spaceId: Int64,
    currentParticipants: [UserInfo],
    currentGroupParticipants: [UserGroup],
    db: AppDatabase
  ) {
    self.chatId = chatId
    self.spaceId = spaceId
    self.currentParticipantIds = Set(currentParticipants.map { $0.user.id })
    self.currentGroupIds = Set(currentGroupParticipants.map(\.id))
    self.db = db
    self.spaceViewModel = SpaceFullMembersViewModel(db: db, spaceId: spaceId)
    self.groupsViewModel = UserGroupsViewModel(db: db, spaceId: spaceId)

    availableMembers = spaceViewModel.members
    availableGroups = groupsViewModel.groups
    isLoading = availableMembers.isEmpty
    errorMessage = spaceViewModel.errorMessage

    observeSpaceMembers()
    observeGroups()
    Task { await requestMembersIfNeeded() }
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

  private func observeGroups() {
    groupsViewModel.$groups
      .receive(on: DispatchQueue.main)
      .sink { [weak self] groups in
        self?.availableGroups = groups
      }
      .store(in: &cancellables)

    groupsViewModel.$errorMessage
      .receive(on: DispatchQueue.main)
      .sink { [weak self] error in
        guard self?.errorMessage == nil else { return }
        self?.errorMessage = error
      }
      .store(in: &cancellables)
  }

  func loadMembers() async {
    await requestMembersIfNeeded()
  }

  private func requestMembersIfNeeded() async {
    guard !didRequestMembers else { return }
    didRequestMembers = true
    await spaceViewModel.refetchMembers()
    await groupsViewModel.loadIfNeeded()
  }

  func toggleSelection(userId: Int64) {
    if selectedUserIds.contains(userId) {
      selectedUserIds.remove(userId)
    } else {
      selectedUserIds.insert(userId)
    }
  }

  func toggleGroupSelection(groupId: Int64) {
    if selectedGroupIds.contains(groupId) {
      selectedGroupIds.remove(groupId)
    } else {
      selectedGroupIds.insert(groupId)
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

      for groupId in selectedGroupIds {
        try await Api.realtime.send(.addChatParticipant(
          chatID: chatId,
          groupID: groupId
        ))
      }

      selectedUserIds.removeAll()
      selectedGroupIds.removeAll()
      isLoading = false
    } catch {
      isLoading = false
      errorMessage = error.localizedDescription
      Log.shared.error("Failed to add participants", error: error)
      throw error
    }
  }
}
