import InlineKit
import SwiftUI

class ChatInfoViewEnvironment: ObservableObject {
  @Binding var isSearching: Bool
  let isPrivate: Bool
  let isDM: Bool
  let isOwnerOrAdmin: Bool
  let participants: [UserInfo]
  let chatId: Int64
  let chatItem: SpaceChatItem
  let spaceMembersViewModel: SpaceMembersViewModel
  let space: Space?
  let removeParticipant: (UserInfo) -> Void
  let openParticipantChat: (UserInfo) -> Void

  init(
    isSearching: Binding<Bool>,
    isPrivate: Bool,
    isDM: Bool,
    isOwnerOrAdmin: Bool,
    participants: [UserInfo],
    chatId: Int64,
    chatItem: SpaceChatItem,
    spaceMembersViewModel: SpaceMembersViewModel,
    space: Space?,
    removeParticipant: @escaping (UserInfo) -> Void,
    openParticipantChat: @escaping (UserInfo) -> Void
  ) {
    _isSearching = isSearching
    self.isPrivate = isPrivate
    self.isDM = isDM
    self.isOwnerOrAdmin = isOwnerOrAdmin
    self.participants = participants
    self.chatId = chatId
    self.chatItem = chatItem
    self.spaceMembersViewModel = spaceMembersViewModel
    self.space = space
    self.removeParticipant = removeParticipant
    self.openParticipantChat = openParticipantChat
  }
}
