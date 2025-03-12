import { deleteMessage } from "@in/server/functions/messages.deleteMessage"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { getChatHistory } from "@in/server/functions/messages.getChatHistory"
import { addReaction } from "./messages.addReaction"
import { deleteReaction } from "./messages.deleteReaction"
export const Functions = {
  messages: {
    deleteMessage: deleteMessage,
    sendMessage: sendMessage,
    getChatHistory: getChatHistory,
    addReaction: addReaction,
    deleteReaction: deleteReaction,
  },
}
