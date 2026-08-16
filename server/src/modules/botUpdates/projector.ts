import type {
  BotActivationReason,
  BotEventChat,
  BotEventMessage,
  BotFile,
  BotMedia,
  BotMessageAction,
  BotReaction,
  BotUser,
  BotAgent,
} from "@inline-chat/bot-api-types"
import type { MessageActions, MessageEntities } from "@inline-chat/protocol/core"
import { BotUpdatesModel } from "@in/server/db/models/botUpdates"
import { MessageModel, type DbFullMessage } from "@in/server/db/models/messages"
import { UsersModel } from "@in/server/db/models/users"
import { BotAgentsModel } from "@in/server/db/models/botAgents"
import type { DbChat, DbUser } from "@in/server/db/schema"
import { encodeBotEntities, type BotUserJson } from "@in/server/controllers/bot/entityCodec"
import type { UpdateGroup } from "@in/server/modules/updates"
import { Log } from "@in/server/utils/log"

const log = new Log("botUpdates.projector")

const unixSeconds = (value: Date | number) =>
  value instanceof Date ? Math.floor(value.getTime() / 1_000) : Number(value)

const toUser = (user: DbUser | BotUserJson): BotUser => ({
  id: user.id,
  is_bot: "bot" in user ? Boolean(user.bot) : user.is_bot,
  username: user.username ?? undefined,
  first_name: "firstName" in user ? user.firstName ?? undefined : user.first_name,
  last_name: "lastName" in user ? user.lastName ?? undefined : user.last_name,
})

const toEventChat = (chat: DbChat): BotEventChat => ({
  chat_id: chat.id,
  type: chat.type === "private" ? "user" : "thread",
  title: chat.title ?? undefined,
  space_id: chat.spaceId ?? undefined,
  is_public: chat.publicThread ?? undefined,
  parent_chat_id: chat.parentChatId ?? undefined,
  emoji: chat.emoji ?? undefined,
})

const mentionTargets = (entities: MessageEntities | null | undefined): number[] =>
  (entities?.entities ?? []).flatMap((entity) => {
    if (entity.entity.oneofKind === "mention") return [Number(entity.entity.mention.userId)]
    return []
  })

export const agentMentionTarget = (
  entities: MessageEntities | null | undefined,
  botUserId: number,
): number | undefined => {
  for (const entity of entities?.entities ?? []) {
    if (entity.entity.oneofKind !== "mention") continue
    if (Number(entity.entity.mention.userId) !== botUserId) continue
    if (entity.entity.mention.agentId !== undefined) return Number(entity.entity.mention.agentId)
  }
  return undefined
}

const toAgent = (agent: import("@inline-chat/protocol/core").BotAgent): BotAgent => ({
  id: Number(agent.id),
  bot_user_id: Number(agent.botUserId),
  name: agent.name,
  handle: agent.handle,
  emoji: agent.emoji,
  description: agent.description,
  skill_key: agent.skillKey,
  instructions: agent.instructions,
})

const commandTargets = (entities: MessageEntities | null | undefined): number[] =>
  (entities?.entities ?? []).flatMap((entity) => {
    if (entity.entity.oneofKind === "botCommand") return [Number(entity.entity.botCommand.botUserId)]
    return []
  })

export const encodeBotActions = (actions: MessageActions | null | undefined): BotMessageAction[][] | undefined =>
  actions?.rows.map((row) => row.actions.flatMap<BotMessageAction>((action) => {
    if (action.action.oneofKind === "copyText") {
      return [{ action_id: action.actionId, text: action.text, type: "copy_text", copy_text: action.action.copyText.text }]
    }
    if (action.action.oneofKind !== "callback") return []
    const bytes = Buffer.from(action.action.callback.data)
    const text = bytes.toString("utf8")
    return [Buffer.from(text, "utf8").equals(bytes)
      ? { action_id: action.actionId, text: action.text, type: "callback", callback_data: text }
      : { action_id: action.actionId, text: action.text, type: "callback", callback_data_base64: bytes.toString("base64") }]
  }))

const toFile = (file: {
  fileUniqueId: string
  mimeType?: string | null
  fileSize?: number | null
  width?: number | null
  height?: number | null
  videoDuration?: number | null
}): BotFile => ({
  file_id: file.fileUniqueId,
  mime_type: file.mimeType ?? undefined,
  file_size: file.fileSize ?? undefined,
  width: file.width ?? undefined,
  height: file.height ?? undefined,
  duration: file.videoDuration ?? undefined,
})

const photoFile = (photo: DbFullMessage["photo"]): BotFile | undefined => {
  const size = photo?.photoSizes?.reduce((best, candidate) => {
    const area = (candidate.width ?? 0) * (candidate.height ?? 0)
    const bestArea = (best?.width ?? 0) * (best?.height ?? 0)
    return area >= bestArea ? candidate : best
  }, photo.photoSizes[0])
  return size?.file ? { ...toFile(size.file), width: size.width ?? undefined, height: size.height ?? undefined } : undefined
}

export const encodeBotMedia = (message: DbFullMessage): BotMedia | undefined => {
  const photo = photoFile(message.photo)
  if (photo) return { type: "photo", file: photo }
  if (message.video) return {
    type: "video",
    file: { ...toFile(message.video.file), width: message.video.width ?? undefined, height: message.video.height ?? undefined, duration: message.video.duration ?? undefined },
    thumbnail: photoFile(message.video.photo),
    is_animated: message.video.isAnimated,
    has_audio: message.video.hasAudio ?? undefined,
  }
  if (message.document) return { type: "document", file: toFile(message.document.file), thumbnail: photoFile(message.document.photo) }
  if (message.voice) return {
    type: "voice",
    file: { ...toFile(message.voice.file), duration: message.voice.duration ?? undefined },
    waveform_base64: message.voice.waveform ? Buffer.from(message.voice.waveform).toString("base64") : undefined,
  }
  if (message.mediaType === "nudge") return { type: "nudge" }
  return undefined
}

async function loadUsers(ids: number[]): Promise<Map<number, BotUserJson>> {
  const rows = await UsersModel.getUsersWithPhotos(Array.from(new Set(ids.filter((id) => id > 0))))
  return new Map(rows.map(({ user }) => [user.id, {
    id: user.id,
    is_bot: Boolean(user.bot),
    username: user.username ?? undefined,
    first_name: user.firstName ?? undefined,
    last_name: user.lastName ?? undefined,
  }]))
}

const messageLite = (
  message: DbFullMessage,
  chat: BotEventChat,
  users: Map<number, BotUserJson>,
) => ({
  message_id: message.messageId,
  chat_id: message.chatId,
  chat,
  peer: chat.type === "user" ? {} : { thread_id: chat.chat_id },
  from_id: message.fromId,
  from: toUser(users.get(message.fromId) ?? message.from),
  date: unixSeconds(message.date),
  edit_date: message.editDate ? unixSeconds(message.editDate) : undefined,
  text: message.text ?? undefined,
  entities: encodeBotEntities(message.entities, { usersById: users }),
  media: encodeBotMedia(message),
  actions: encodeBotActions(message.actions),
})

async function eventMessage(chatRow: DbChat, message: DbFullMessage): Promise<BotEventMessage> {
  const reply = message.replyToMsgId
    ? await MessageModel.getMessage(message.replyToMsgId, chatRow.id).catch(() => null)
    : null
  const users = await loadUsers([
    message.fromId,
    ...mentionTargets(message.entities),
    ...(reply ? [reply.fromId, ...mentionTargets(reply.entities)] : []),
  ])
  const chat = toEventChat(chatRow)
  return {
    ...messageLite(message, chat, users),
    reply_to_message: reply ? messageLite(reply, chat, users) : undefined,
  }
}

export const activationReason = (input: {
  stream: { botUserId: number; messageTrigger: string }
  chat: DbChat
  message: DbFullMessage
  reply: DbFullMessage | null
}): BotActivationReason | undefined => {
  if (input.message.fromId === input.stream.botUserId) return undefined
  const explicitlyMentioned = mentionTargets(input.message.entities).includes(input.stream.botUserId)
  if (input.message.from.bot) return explicitlyMentioned ? "mention" : undefined
  if (commandTargets(input.message.entities).includes(input.stream.botUserId)) return "command"
  if (explicitlyMentioned) return "mention"
  if (input.reply?.fromId === input.stream.botUserId) return "reply"
  if (input.chat.type === "private") return "direct"
  return input.stream.messageTrigger === "all" ? "all" : undefined
}

async function messageCreated(input: {
  chat: DbChat
  messageId: number
  updateGroup: UpdateGroup
}): Promise<void> {
  const [message, streams] = await Promise.all([
    MessageModel.getMessage(input.messageId, input.chat.id),
    BotUpdatesModel.getStreamsForBotUserIds(input.updateGroup.userIds),
  ])
  if (streams.length === 0) return
  const reply = message.replyToMsgId
    ? await MessageModel.getMessage(message.replyToMsgId, input.chat.id).catch(() => null)
    : null
  const encoded = await eventMessage(input.chat, message)
  for (const stream of streams) {
    const reason = activationReason({ stream, chat: input.chat, message, reply })
    if (!reason) continue
    await BotUpdatesModel.recordMessageRoute({
      botUserId: stream.botUserId,
      chatId: input.chat.id,
      messageId: input.messageId,
      activationReason: reason,
    })
    const mentionedAgentId = agentMentionTarget(message.entities, stream.botUserId)
    const mentionedAgent = mentionedAgentId ? await BotAgentsModel.get(mentionedAgentId) : undefined
    const activatedAgent = mentionedAgent && Number(mentionedAgent.botUserId) === stream.botUserId
      ? toAgent(mentionedAgent)
      : undefined
    await BotUpdatesModel.queue({
      botUserId: stream.botUserId,
      updateType: "message",
      payload: { activation_reason: reason, ...(activatedAgent ? { activated_agent: activatedAgent } : {}), message: encoded },
      sourceEventId: `message:${input.chat.id}:${input.messageId}`,
    })
  }
}

async function messageEdited(input: { chat: DbChat; messageId: number }): Promise<void> {
  const routes = await BotUpdatesModel.getMessageRoutes(input.chat.id, [input.messageId])
  if (routes.length === 0) return
  const message = await MessageModel.getMessage(input.messageId, input.chat.id)
  const encoded = await eventMessage(input.chat, message)
  for (const route of routes) {
    await BotUpdatesModel.queue({
      botUserId: route.botUserId,
      updateType: "edited_message",
      payload: { activation_reason: route.activationReason as BotActivationReason, edited_message: encoded },
      sourceEventId: `edit:${input.chat.id}:${input.messageId}:${message.editDate?.getTime() ?? Date.now()}`,
    })
  }
}

async function messagesDeleted(input: { chat: DbChat; messageIds: bigint[]; actorUserId: number }): Promise<void> {
  const ids = input.messageIds.map(Number)
  const [routes, actorRows] = await Promise.all([
    BotUpdatesModel.getMessageRoutes(input.chat.id, ids),
    UsersModel.getUsersWithPhotos([input.actorUserId]),
  ])
  const actor = actorRows[0]?.user
  for (const route of routes) {
    await BotUpdatesModel.queue({
      botUserId: route.botUserId,
      updateType: "deleted_messages",
      payload: {
        activation_reason: route.activationReason as BotActivationReason,
        deleted_messages: {
          chat: toEventChat(input.chat),
          message_ids: ids,
          actor: actor ? toUser(actor) : undefined,
          date: Math.floor(Date.now() / 1_000),
        },
      },
    })
  }
}

async function reactionChanged(input: {
  chat: DbChat
  messageId: number
  actorUserId: number
  emoji: string
  added: boolean
}): Promise<void> {
  const [routes, actors] = await Promise.all([
    BotUpdatesModel.getMessageRoutes(input.chat.id, [input.messageId]),
    UsersModel.getUsersWithPhotos([input.actorUserId]),
  ])
  const actor = actors[0]?.user
  if (!actor) return
  const reaction: BotReaction[] = [{ emoji: input.emoji }]
  for (const route of routes) {
    await BotUpdatesModel.queue({
      botUserId: route.botUserId,
      updateType: "message_reaction",
      payload: {
        activation_reason: route.activationReason as BotActivationReason,
        message_reaction: {
          chat: toEventChat(input.chat), message_id: input.messageId, actor: toUser(actor),
          date: Math.floor(Date.now() / 1_000),
          old_reaction: input.added ? [] : reaction,
          new_reaction: input.added ? reaction : [],
        },
      },
    })
  }
}

async function actionInvoked(input: {
  botUserId: number
  chat: DbChat
  messageId: number
  actorUserId: number
  actionId: string
  interactionId: bigint
  data: Uint8Array
}): Promise<void> {
  const actor = (await UsersModel.getUsersWithPhotos([input.actorUserId]))[0]?.user
  if (!actor) return
  const bytes = Buffer.from(input.data)
  const value = bytes.toString("utf8")
  await BotUpdatesModel.queue({
    botUserId: input.botUserId,
    updateType: "message_action",
    payload: {
      activation_reason: "action",
      message_action: {
        interaction_id: Number(input.interactionId), chat: toEventChat(input.chat),
        message_id: input.messageId, actor: toUser(actor), date: Math.floor(Date.now() / 1_000),
        action: Buffer.from(value, "utf8").equals(bytes)
          ? { action_id: input.actionId, callback_data: value }
          : { action_id: input.actionId, callback_data_base64: bytes.toString("base64") },
      },
    },
    sourceEventId: `action:${input.botUserId}:${input.interactionId}`,
  })
}

async function participationChanged(input: {
  botUserId: number
  chat: DbChat
  actorUserId: number
  added: boolean
}): Promise<void> {
  const [bot, actor] = await Promise.all([
    UsersModel.getUserById(input.botUserId),
    UsersModel.getUserById(input.actorUserId),
  ])
  if (!bot?.bot) return
  await BotUpdatesModel.queue({
    botUserId: input.botUserId,
    updateType: "bot_participation",
    payload: {
      bot_participation: {
        chat: toEventChat(input.chat),
        actor: actor ? toUser(actor) : undefined,
        date: Math.floor(Date.now() / 1_000),
        status: input.added ? "added" : "removed",
      },
    },
  })
}

const safely = <T extends unknown[]>(name: string, fn: (...args: T) => Promise<void>) =>
  (...args: T): void => {
    void fn(...args).catch((error) => log.error(`Failed to project ${name}`, { error }))
  }

export const BotUpdateProjector = {
  messageCreated: safely("message", messageCreated),
  messageEdited: safely("edited message", messageEdited),
  messagesDeleted: safely("deleted messages", messagesDeleted),
  reactionChanged: safely("reaction", reactionChanged),
  actionInvoked: safely("message action", actionInvoked),
  participationChanged: safely("bot participation", participationChanged),
}
