import { Layer } from "effect"
import { handler as addReactionHandler } from "@in/server/methods/addReaction"
import { handler as createPrivateChatHandler } from "@in/server/methods/createPrivateChat"
import { handler as createThreadHandler } from "@in/server/methods/createThread"
import { handler as deleteMessageHandler } from "@in/server/methods/deleteMessage"
import { handler as getChatHistoryHandler } from "@in/server/methods/getChatHistory"
import { handler as getDialogsHandler } from "@in/server/methods/getDialogs"
import { handler as getDraftHandler } from "@in/server/methods/getDraft"
import { handler as getPrivateChatsHandler } from "@in/server/methods/getPrivateChats"
import { handler as readMessagesHandler } from "@in/server/methods/readMessages"
import { handler as sendComposeActionHandler } from "@in/server/methods/sendComposeAction"
import { handler as sendMessageHandler } from "@in/server/methods/sendMessage"
import { handler as sendMessage20250509Handler } from "@in/server/methods/sendMessage_20250509"
import { handler as updateDialogHandler } from "@in/server/methods/updateDialog"
import { V1MessagingOperations } from "./v1MessagingOperations.effect"
import { makeV1MessagingOperations } from "./v1MessagingOperationsAdapter.effect"

// TODO(effect-cutover): replace retained method bindings as individual messaging operations become Effect-native.
export const V1MessagingOperationsLive = Layer.succeed(
  V1MessagingOperations,
  makeV1MessagingOperations({
    addReaction: (input, context) => addReactionHandler({ ...input }, context),
    createPrivateChat: (input, context) => createPrivateChatHandler({ ...input }, context),
    createThread: (input, context) => createThreadHandler({ ...input }, context),
    deleteMessage: (input, context) => deleteMessageHandler({ ...input }, context),
    getChatHistory: (input, context) => getChatHistoryHandler({ ...input }, context),
    getDialogs: (input, context) => getDialogsHandler({ ...input }, context),
    getDraft: (input, context) => getDraftHandler({ ...input }, context),
    getPrivateChats: (_input, context) => getPrivateChatsHandler({}, context),
    readMessages: (input, context) => readMessagesHandler({ ...input }, context),
    sendComposeAction: (input, context) => sendComposeActionHandler({ ...input }, context),
    sendMessage: (input, context) => sendMessageHandler({ ...input }, context),
    sendMessage20250509: (input, context) => sendMessage20250509Handler({ ...input }, context),
    updateDialog: (input, context) => updateDialogHandler({ ...input }, context),
  }),
)
