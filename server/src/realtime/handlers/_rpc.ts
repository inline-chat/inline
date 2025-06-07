import { Method, type ConnectionInit, type ConnectionOpen, type RpcCall, type RpcResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { getUserIdFromToken } from "@in/server/controllers/plugins"
import { connectionManager } from "@in/server/ws/connections"
import { getMe } from "@in/server/realtime/handlers/getMe"
import { Log } from "@in/server/utils/log"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { deleteMessage } from "@in/server/realtime/handlers/messages.deleteMessage"
import { sendMessage } from "@in/server/realtime/handlers/messages.sendMessage"
import { getChatHistory } from "@in/server/realtime/handlers/messages.getChatHistory"
import { addReaction } from "./messages.addReactions"
import { deleteReaction } from "./messages.deleteReaction"
import { editMessage } from "./messages.editMessage"
import { createChat } from "@in/server/realtime/handlers/messages.createChat"
import { getSpaceMembers } from "@in/server/realtime/handlers/space.getSpaceMembers"
import { deleteChatHandler } from "@in/server/realtime/handlers/messages.deleteChat"
import { inviteToSpace } from "@in/server/functions/space.inviteToSpace"
import { getChatParticipants } from "@in/server/realtime/handlers/messages.getChatParticipants"
import { addChatParticipant } from "@in/server/realtime/handlers/messages.addChatParticipant"
import { removeChatParticipant } from "@in/server/realtime/handlers/messages.removeChatParticipant"
import { handleTranslateMessages } from "./translateMessages"
import { handleGetChats } from "./messages.getChats"
import { getUserSettingsHandler } from "./user.getUserSettings"
import { updateUserSettingsHandler } from "./user.updateUserSettings"
import { sendComposeActionHandler } from "./messages.sendComposeAction"
import { createBotHandler } from "./createBot"

export const handleRpcCall = async (call: RpcCall, handlerContext: HandlerContext): Promise<RpcResult["result"]> => {
  // user still unauthenticated here.
  Log.shared.debug("rpc call", Method[call.method])

  switch (call.method) {
    case Method.GET_ME: {
      if (call.input.oneofKind !== "getMe") {
        throw RealtimeRpcError.BadRequest
      }
      let result = await getMe(call.input, handlerContext)
      return { oneofKind: "getMe", getMe: result }
    }

    case Method.DELETE_MESSAGES: {
      if (call.input.oneofKind !== "deleteMessages") {
        throw RealtimeRpcError.BadRequest
      }
      let result = await deleteMessage(call.input.deleteMessages, handlerContext)
      return { oneofKind: "deleteMessages", deleteMessages: result }
    }

    case Method.SEND_MESSAGE: {
      if (call.input.oneofKind !== "sendMessage") {
        throw RealtimeRpcError.BadRequest
      }
      let result = await sendMessage(call.input.sendMessage, handlerContext)
      return { oneofKind: "sendMessage", sendMessage: result }
    }

    case Method.GET_CHAT_HISTORY: {
      if (call.input.oneofKind !== "getChatHistory") {
        throw RealtimeRpcError.BadRequest
      }
      let result = await getChatHistory(call.input.getChatHistory, handlerContext)
      return { oneofKind: "getChatHistory", getChatHistory: result }
    }

    case Method.ADD_REACTION: {
      if (call.input.oneofKind !== "addReaction") {
        throw RealtimeRpcError.BadRequest
      }
      let result = await addReaction(call.input.addReaction, handlerContext)
      return { oneofKind: "addReaction", addReaction: result }
    }

    case Method.DELETE_REACTION: {
      if (call.input.oneofKind !== "deleteReaction") {
        throw RealtimeRpcError.BadRequest
      }
      let result = await deleteReaction(call.input.deleteReaction, handlerContext)
      return { oneofKind: "deleteReaction", deleteReaction: result }
    }

    case Method.EDIT_MESSAGE: {
      if (call.input.oneofKind !== "editMessage") {
        throw RealtimeRpcError.BadRequest
      }
      let result = await editMessage(call.input.editMessage, handlerContext)
      return { oneofKind: "editMessage", editMessage: result }
    }

    case Method.CREATE_CHAT: {
      if (call.input.oneofKind !== "createChat") {
        throw RealtimeRpcError.BadRequest
      }
      let result = await createChat(call.input.createChat, handlerContext)
      return { oneofKind: "createChat", createChat: result }
    }

    case Method.GET_SPACE_MEMBERS: {
      if (call.input.oneofKind !== "getSpaceMembers") {
        throw RealtimeRpcError.BadRequest
      }
      let result = await getSpaceMembers(call.input.getSpaceMembers, handlerContext)
      return { oneofKind: "getSpaceMembers", getSpaceMembers: result }
    }

    case Method.DELETE_CHAT: {
      if (call.input.oneofKind !== "deleteChat") {
        throw RealtimeRpcError.BadRequest
      }
      let result = await deleteChatHandler(call.input.deleteChat, handlerContext)
      return { oneofKind: "deleteChat", deleteChat: result }
    }

    case Method.INVITE_TO_SPACE: {
      if (call.input.oneofKind !== "inviteToSpace") {
        throw RealtimeRpcError.BadRequest
      }
      let result = await inviteToSpace(call.input.inviteToSpace, {
        currentUserId: handlerContext.userId,
        currentSessionId: handlerContext.sessionId,
      })
      return { oneofKind: "inviteToSpace", inviteToSpace: result }
    }

    case Method.GET_CHAT_PARTICIPANTS: {
      if (call.input.oneofKind !== "getChatParticipants") {
        throw RealtimeRpcError.BadRequest
      }
      let result = await getChatParticipants(call.input.getChatParticipants, handlerContext)
      return { oneofKind: "getChatParticipants", getChatParticipants: result }
    }

    case Method.ADD_CHAT_PARTICIPANT: {
      if (call.input.oneofKind !== "addChatParticipant") {
        throw RealtimeRpcError.BadRequest
      }
      let result = await addChatParticipant(call.input.addChatParticipant, handlerContext)
      return { oneofKind: "addChatParticipant", addChatParticipant: result }
    }

    case Method.REMOVE_CHAT_PARTICIPANT: {
      if (call.input.oneofKind !== "removeChatParticipant") {
        throw RealtimeRpcError.BadRequest
      }
      let result = await removeChatParticipant(call.input.removeChatParticipant, handlerContext)
      return { oneofKind: "removeChatParticipant", removeChatParticipant: result }
    }

    case Method.TRANSLATE_MESSAGES: {
      if (call.input.oneofKind !== "translateMessages") {
        throw RealtimeRpcError.BadRequest
      }
      let result = await handleTranslateMessages(call.input.translateMessages, handlerContext)
      return { oneofKind: "translateMessages", translateMessages: result }
    }

    case Method.GET_CHATS: {
      if (call.input.oneofKind !== "getChats") {
        throw RealtimeRpcError.BadRequest
      }
      let result = await handleGetChats(call.input.getChats, handlerContext)
      return { oneofKind: "getChats", getChats: result }
    }

    case Method.GET_USER_SETTINGS: {
      if (call.input.oneofKind !== "getUserSettings") {
        throw RealtimeRpcError.BadRequest
      }
      let result = await getUserSettingsHandler(call.input.getUserSettings, handlerContext)
      return { oneofKind: "getUserSettings", getUserSettings: result }
    }

    case Method.UPDATE_USER_SETTINGS: {
      if (call.input.oneofKind !== "updateUserSettings") {
        throw RealtimeRpcError.BadRequest
      }
      let result = await updateUserSettingsHandler(call.input.updateUserSettings, handlerContext)
      return { oneofKind: "updateUserSettings", updateUserSettings: result }
    }

    case Method.SEND_COMPOSE_ACTION: {
      if (call.input.oneofKind !== "sendComposeAction") {
        throw RealtimeRpcError.BadRequest
      }
      let result = await sendComposeActionHandler(call.input.sendComposeAction, handlerContext)
      return { oneofKind: "sendComposeAction", sendComposeAction: result }
    }

    case Method.CREATE_BOT: {
      if (call.input.oneofKind !== "createBot") {
        throw RealtimeRpcError.BadRequest
      }
      let result = await createBotHandler(call.input.createBot, handlerContext)
      return { oneofKind: "createBot", createBot: result }
    }

    default:
      Log.shared.error(`Unknown method: ${call.method}`)
      throw RealtimeRpcError.BadRequest
  }
}

export const handlers = {
  translateMessages: handleTranslateMessages,
  getChats: handleGetChats,
}
