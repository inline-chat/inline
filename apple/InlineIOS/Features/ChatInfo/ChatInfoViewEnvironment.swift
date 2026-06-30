import InlineKit
import SwiftUI

class ChatInfoViewEnvironment: ObservableObject {
  @Binding var isSearching: Bool
  let isPrivate: Bool
  let isDM: Bool
  let isOwnerOrAdmin: Bool
  let participants: [UserInfo]
  let groupParticipants: [UserGroup]
  let chatId: Int64
  let chatItem: SpaceChatItem
  let notificationSelection: DialogNotificationSettingSelection
  let spaceMembersViewModel: SpaceMembersViewModel
  let space: Space?
  let removeParticipant: (UserInfo) -> Void
  let removeGroupParticipant: (UserGroup) -> Void
  let openParticipantChat: (UserInfo) -> Void
  let updateNotificationSelection: (DialogNotificationSettingSelection) -> Void
  let requestMakePublic: () -> Void
  let requestMakePrivate: () -> Void

  init(
    isSearching: Binding<Bool>,
    isPrivate: Bool,
    isDM: Bool,
    isOwnerOrAdmin: Bool,
    participants: [UserInfo],
    groupParticipants: [UserGroup],
    chatId: Int64,
    chatItem: SpaceChatItem,
    notificationSelection: DialogNotificationSettingSelection,
    spaceMembersViewModel: SpaceMembersViewModel,
    space: Space?,
    removeParticipant: @escaping (UserInfo) -> Void,
    removeGroupParticipant: @escaping (UserGroup) -> Void,
    openParticipantChat: @escaping (UserInfo) -> Void,
    updateNotificationSelection: @escaping (DialogNotificationSettingSelection) -> Void,
    requestMakePublic: @escaping () -> Void,
    requestMakePrivate: @escaping () -> Void
  ) {
    _isSearching = isSearching
    self.isPrivate = isPrivate
    self.isDM = isDM
    self.isOwnerOrAdmin = isOwnerOrAdmin
    self.participants = participants
    self.groupParticipants = groupParticipants
    self.chatId = chatId
    self.chatItem = chatItem
    self.notificationSelection = notificationSelection
    self.spaceMembersViewModel = spaceMembersViewModel
    self.space = space
    self.removeParticipant = removeParticipant
    self.removeGroupParticipant = removeGroupParticipant
    self.openParticipantChat = openParticipantChat
    self.updateNotificationSelection = updateNotificationSelection
    self.requestMakePublic = requestMakePublic
    self.requestMakePrivate = requestMakePrivate
  }
}
