import Combine
import InlineKit
import Logger
import SwiftUI

@MainActor
final class SelectParticipantsViewModel: ObservableObject {
  @Published private(set) var availableMembers: [FullMemberItem] = []
  @Published private(set) var isLoading = true
  @Published private(set) var errorMessage: String?
  @Published var searchText = ""

  private let spaceViewModel: SpaceFullMembersViewModel
  private let db: AppDatabase
  private var cancellables = Set<AnyCancellable>()

  var filteredMembers: [FullMemberItem] {
    if searchText.isEmpty {
      return availableMembers
    }

    return availableMembers.filter { member in
      let name = "\(member.userInfo.user.firstName ?? "") \(member.userInfo.user.lastName ?? "")"
        .trimmingCharacters(in: .whitespaces)
      let username = member.userInfo.user.username ?? ""
      let email = member.userInfo.user.email ?? ""

      return name.localizedCaseInsensitiveContains(searchText) ||
        username.localizedCaseInsensitiveContains(searchText) ||
        email.localizedCaseInsensitiveContains(searchText)
    }
  }

  init(spaceId: Int64, db: AppDatabase) {
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
}
