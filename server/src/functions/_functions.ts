import { deleteMessage } from "@in/server/functions/messages.deleteMessage"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { getChatHistory } from "@in/server/functions/messages.getChatHistory"
import { getChat } from "@in/server/functions/messages.getChat"
import { searchMessages } from "@in/server/functions/messages.searchMessages"
import { addReaction } from "./messages.addReaction"
import { deleteReaction } from "./messages.deleteReaction"
import { editMessage } from "./messages.editMessage"
import { createChat } from "./messages.createChat"
import { getSpaceMembers } from "./space.getSpaceMembers"
import { deleteChat } from "./messages.deleteChat"
import { inviteToSpace } from "./space.inviteToSpace"
import { updateMemberAccess } from "./space.updateMemberAccess"
import { getChatParticipants } from "./messages.getChatParticipants"
import { removeChatParticipant } from "./messages.removeChatParticipant"
import { addChatParticipant } from "./messages.addChatParticipant"
import { updateChatVisibility } from "./messages.updateChatVisibility"
import { updateChatInfo } from "./messages.updateChatInfo"
import { pinMessage } from "./messages.pinMessage"
import { getUserSettings } from "./user.getUserSettings"
import { updateUserSettings } from "./user.updateUserSettings"
import { createBot } from "./createBot"
import { deleteMember } from "@in/server/functions/space.deleteMember"
import { markAsUnread } from "./messages.markAsUnread"
import { getUpdatesState } from "./updates.getUpdatesState"
import { getUpdates } from "./updates.getUpdates"
import { forwardMessages } from "./messages.forwardMessages"

export const Functions = {
  messages: {
    deleteMessage: deleteMessage,
    sendMessage: sendMessage,
    getChatHistory: getChatHistory,
    searchMessages: searchMessages,
    getChat: getChat,
    addReaction: addReaction,
    deleteReaction: deleteReaction,
    editMessage: editMessage,
    createChat: createChat,
    deleteChat: deleteChat,
    getChatParticipants: getChatParticipants,
    addChatParticipant: addChatParticipant,
    removeChatParticipant: removeChatParticipant,
    updateChatVisibility: updateChatVisibility,
    updateChatInfo: updateChatInfo,
    pinMessage: pinMessage,
    forwardMessages: forwardMessages,
    // until we make tests pass
    //markAsUnread: markAsUnread,
  },
  spaces: {
    getSpaceMembers: getSpaceMembers,
    inviteToSpace: inviteToSpace,
    deleteMember: deleteMember,
    updateMemberAccess: updateMemberAccess,
  },
  user: {
    getUserSettings: getUserSettings,
    updateUserSettings: updateUserSettings,
  },
  bot: {
    createBot: createBot,
  },
  updates: {
    getUpdatesState: getUpdatesState,
    getUpdates: getUpdates,
  },
}
