import type { InputPeer, MessageFormSubmission, MessageWidgetCall, Update } from "@inline-chat/protocol/core"
import { AgentGrantRequirement } from "@inline-chat/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import { MessageModel } from "@in/server/db/models/messages"
import { UsersModel } from "@in/server/db/models/users"
import type { FunctionContext } from "@in/server/functions/_types"
import { resolveAgentAccess, satisfiesGrantRequirement } from "@in/server/modules/agents/grants"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { findCallbackAction } from "@in/server/modules/message/messageActions"
import { findForm, validateFormSubmission } from "@in/server/modules/message/messageForms"
import { findWidget, MessageWidgetError, validateWidgetCall } from "@in/server/modules/message/messageWidgets"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { BotUpdateProjector } from "@in/server/modules/botUpdates/projector"

type Input = {
  peerId: InputPeer
  messageId: bigint
  actionId: string
  form?: MessageFormSubmission
  widgetCall?: MessageWidgetCall
}

type Output = {
  interactionId: bigint
}

export const invokeMessageAction = async (input: Input, context: FunctionContext): Promise<Output> => {
  const chat = await ChatModel.getChatFromInputPeerUnchecked(input.peerId, context)
  // Owners who opened the chat through their bot may act only on that bot's messages.
  const throughManagedBot = !(await AccessGuards.hasChatAccess(chat, context.currentUserId))
  if (throughManagedBot) await AccessGuards.ensureChatReadAccess(chat, context.currentUserId)

  const messageId = Number(input.messageId)
  if (!Number.isSafeInteger(messageId) || messageId <= 0) {
    throw RealtimeRpcError.MessageIdInvalid()
  }

  const message = await MessageModel.getMessage(messageId, chat.id)

  const sender = await UsersModel.getUserById(message.fromId)
  if (!sender?.bot) {
    throw RealtimeRpcError.BadRequest()
  }
  if (throughManagedBot && sender.botCreatorId !== context.currentUserId) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  const actionId = input.actionId.trim()
  // The input names what is invoked, so a widget or form ID never reaches a same-named button.
  if (input.form && input.widgetCall) throw RealtimeRpcError.BadRequest()
  const callback = input.form || input.widgetCall ? null : findCallbackAction({ actions: message.actions, actionId })
  const form = input.form ? findForm(message.blockContent, actionId) : undefined
  const widget = input.widgetCall ? findWidget(message.blockContent, actionId) : undefined
  if (!callback && !form && !widget) {
    throw RealtimeRpcError.BadRequest()
  }

  // Checked before the bot sees anything.
  const requiredGrant = callback?.requiredGrant ?? form?.requiredGrant ?? widget?.requiredGrant ?? AgentGrantRequirement.NONE
  if (requiredGrant !== AgentGrantRequirement.NONE) {
    const access = await resolveAgentAccess(sender, context.currentUserId)
    if (!satisfiesGrantRequirement(access, requiredGrant)) throw RealtimeRpcError.AgentGrantRequired()
  }

  const submission = form && input.form ? validateFormSubmission(form, input.form) : undefined
  let widgetCall: ReturnType<typeof validateWidgetCall> | undefined
  try {
    widgetCall = widget && input.widgetCall ? validateWidgetCall(input.widgetCall) : undefined
  } catch (error) {
    if (error instanceof MessageWidgetError) throw RealtimeRpcError.BadRequest()
    throw error
  }
  const data = callback?.callback.data ?? new Uint8Array()

  // The durable copy never holds secret values; only the live delivery does.
  const userUpdate = await UserBucketUpdates.enqueue({
    userId: sender.id,
    update: {
      oneofKind: "userMessageActionInvoked",
      userMessageActionInvoked: {
        chatId: BigInt(chat.id),
        messageId: BigInt(messageId),
        actorUserId: BigInt(context.currentUserId),
        actionId,
        data,
        form: submission?.stored,
        widgetCall: widgetCall?.call,
      },
    },
  })

  const realtimeUpdate: Update = {
    seq: userUpdate.seq,
    date: encodeDateStrict(userUpdate.date),
    update: {
      oneofKind: "messageActionInvoked",
      messageActionInvoked: {
        interactionId: BigInt(userUpdate.seq),
        chatId: BigInt(chat.id),
        messageId: BigInt(messageId),
        actorUserId: BigInt(context.currentUserId),
        actionId,
        data,
        form: submission?.live,
        widgetCall: widgetCall?.call,
      },
    },
  }

  RealtimeUpdates.pushToUser(sender.id, [realtimeUpdate])

  BotUpdateProjector.actionInvoked({
    botUserId: sender.id, chat, messageId, actorUserId: context.currentUserId,
    actionId, interactionId: BigInt(userUpdate.seq), data, form: submission?.stored,
    widgetCall: widgetCall ? { name: widgetCall.call.name, payload: widgetCall.payload } : undefined,
  })

  return {
    interactionId: BigInt(userUpdate.seq),
  }
}
