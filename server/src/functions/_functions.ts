import { deleteMessage } from "@in/server/functions/messages.deleteMessage"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { getChatHistory } from "@in/server/functions/messages.getChatHistory"
import { addReaction } from "./messages.addReaction"
import { deleteReaction } from "./messages.deleteReaction"
import { editMessage } from "./messages.editMessage"
import { createChat } from "./messages.createChat"
import { getSpaceMembers } from "./space.getSpaceMembers"
import { deleteChat } from "./messages.deleteChat"
import { inviteToSpace } from "./space.inviteToSpace"
import { removeSpaceMember } from "./space.removeSpaceMember"
import { getChatParticipants } from "./messages.getChatParticipants"
import { removeChatParticipant } from "./messages.removeChatParticipant"
import { addChatParticipant } from "./messages.addChatParticipant"
import { getUserSettings } from "./user.getUserSettings"
import { updateUserSettings } from "./user.updateUserSettings"
import { createBot } from "./createBot"

export const Functions = {
  messages: {
    deleteMessage: deleteMessage,
    sendMessage: sendMessage,
    getChatHistory: getChatHistory,
    addReaction: addReaction,
    deleteReaction: deleteReaction,
    editMessage: editMessage,
    createChat: createChat,
    deleteChat: deleteChat,
    getChatParticipants: getChatParticipants,
    addChatParticipant: addChatParticipant,
    removeChatParticipant: removeChatParticipant,
  },
  spaces: {
    getSpaceMembers: getSpaceMembers,
    inviteToSpace: inviteToSpace,
    removeSpaceMember: removeSpaceMember,
  },
  user: {
    getUserSettings: getUserSettings,
    updateUserSettings: updateUserSettings,
  },
  bot: {
    createBot: createBot,
  },
}
