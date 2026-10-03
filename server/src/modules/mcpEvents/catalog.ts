import type { ServerUpdate } from "@in/server/protocol/server"
import type { McpEventSelector, EventBucket } from "./types"
import { McpEventsError, invalidParams } from "./types"

type StoredKind = Exclude<ServerUpdate["update"]["oneofKind"], undefined>
type Definition = { name: string; description: string; scope: "chat" | "space" | "dialog" | "either"; kinds: readonly StoredKind[] }

const chatKinds = ["newMessage", "editMessage", "deleteMessages", "clearChatHistory", "messageAttachment", "acknowledgement", "newChat", "chatVisibility", "chatInfo", "chatMoved", "pinnedMessages", "participantAdd", "participantDelete", "participantGroupAdd", "participantGroupDelete"] as const satisfies readonly StoredKind[]
const spaceKinds = ["spaceMemberAdd", "spaceMemberUpdate", "spaceRemoveMember", "spaceClearHistory", "spaceSettings", "spaceProfile"] as const satisfies readonly StoredKind[]
const dialogKinds = ["userReadMaxId", "userMarkAsUnread", "userDialogArchived", "userDialogNotificationSettings", "userDialogTranslation", "userDialogFollowMode", "userDialogCollapsedMaxId", "userChatOpen", "userChatPermissions", "userDialogFolder"] as const satisfies readonly StoredKind[]

export const eventDefinitions: readonly Definition[] = [
  { name: "message.created", description: "A new message in the selected Inline chat. Contains references; use messages.context to read it.", scope: "chat", kinds: ["newMessage"] },
  { name: "message.updated", description: "A message was edited in the selected chat. Contains a reference to its current state.", scope: "chat", kinds: ["editMessage"] },
  { name: "message.deleted", description: "Messages were deleted in the selected chat.", scope: "chat", kinds: ["deleteMessages"] },
  { name: "message.attachments.updated", description: "A message attachment changed in the selected chat.", scope: "chat", kinds: ["messageAttachment"] },
  { name: "message.history.cleared", description: "Message history was cleared in the selected chat.", scope: "chat", kinds: ["clearChatHistory"] },
  { name: "message.acknowledgement.updated", description: "A message acknowledgement changed in the selected chat.", scope: "chat", kinds: ["acknowledgement"] },
  { name: "chat.created", description: "Legacy name for a journaled chat metadata refresh. It can represent creation or an existing chat being orphaned/detached after history changes; it is not proof that a new chat was created.", scope: "chat", kinds: ["newChat"] },
  { name: "chat.updated", description: "Title, emoji, agent context or other metadata changed in the selected chat, including creation and orphaning/detachment refreshes.", scope: "chat", kinds: ["chatInfo", "newChat"] },
  { name: "chat.visibility.updated", description: "Visibility changed in the selected chat. Delivery stops after access is lost.", scope: "chat", kinds: ["chatVisibility"] },
  { name: "chat.moved", description: "The selected chat moved between home and a space. Delivery remains limited by the current grant.", scope: "chat", kinds: ["chatMoved"] },
  { name: "chat.participants.updated", description: "Direct or group participants changed in the selected chat.", scope: "chat", kinds: ["participantAdd", "participantDelete", "participantGroupAdd", "participantGroupDelete"] },
  { name: "chat.pins.updated", description: "Pinned messages changed in the selected chat.", scope: "chat", kinds: ["pinnedMessages"] },
  { name: "dialog.updated", description: "Your read state, personal chat settings or effective permissions changed for the selected chat.", scope: "dialog", kinds: dialogKinds },
  { name: "space.members.updated", description: "Membership or a member's role changed in the selected space. Contains identifiers, never profile data.", scope: "space", kinds: ["spaceMemberAdd", "spaceMemberUpdate", "spaceRemoveMember"] },
  { name: "space.profile.updated", description: "The selected space's profile changed. Use spaces.list to read current information.", scope: "space", kinds: ["spaceProfile"] },
  { name: "space.settings.updated", description: "The selected space's settings changed.", scope: "space", kinds: ["spaceSettings"] },
  { name: "space.history.cleared", description: "History was cleared across the selected space.", scope: "space", kinds: ["spaceClearHistory"] },
  { name: "inline.update", description: "Journaled changes in the selected current chat or space. Reference-only; account-wide settings and live-only typing, presence and reactions are excluded. Delivery stops when the resource is deleted or access is lost.", scope: "either", kinds: [...chatKinds, ...spaceKinds] },
]

export const eventDefinition = (name: string): Definition => {
  const found = eventDefinitions.find((definition) => definition.name === name)
  if (!found) throw new McpEventsError({ code: -32011, message: "Event not found", data: { kind: "event" } })
  return found
}

const id = (value: unknown): string => {
  if (typeof value !== "string" || !/^[1-9][0-9]{0,9}$/.test(value) || Number(value) > 2_147_483_647) throw invalidParams()
  return value
}

export function parseSelector(name: string, value: unknown): McpEventSelector {
  const definition = eventDefinition(name)
  if (!value || typeof value !== "object" || Array.isArray(value)) throw invalidParams()
  const record = value as Record<string, unknown>
  if ("chatId" in record && !('spaceId' in record) && definition.scope !== "space") {
    const permitsExclude = name === "message.created" || name === "message.updated"
    if (Object.keys(record).some((key) => key !== "chatId" && !(permitsExclude && key === "excludeSelf"))) throw invalidParams()
    if (record["excludeSelf"] !== undefined && typeof record["excludeSelf"] !== "boolean") throw invalidParams()
    return { chatId: id(record["chatId"]), ...(record["excludeSelf"] === true ? { excludeSelf: true } : {}) }
  }
  if ("spaceId" in record && Object.keys(record).length === 1 && (definition.scope === "space" || definition.scope === "either")) return { spaceId: id(record["spaceId"]) }
  throw invalidParams()
}

export function sourceBucket(name: string, selector: McpEventSelector, userId: number): EventBucket {
  if (eventDefinition(name).scope === "dialog") return { kind: "user", entityId: userId }
  return "chatId" in selector ? { kind: "chat", entityId: Number(selector.chatId) } : { kind: "space", entityId: Number(selector.spaceId) }
}

const identifier = { type: "string", pattern: "^[1-9][0-9]*$" }
export const eventCatalog = () => eventDefinitions.map((definition) => ({
  name: definition.name,
  description: definition.description,
  delivery: ["webhook"],
  inputSchema: definition.scope === "either" ? {
    oneOf: [
      { type: "object", properties: { chatId: identifier }, required: ["chatId"], additionalProperties: false },
      { type: "object", properties: { spaceId: identifier }, required: ["spaceId"], additionalProperties: false },
    ],
  } : {
    type: "object",
    properties: definition.scope === "space" ? { spaceId: identifier } : { chatId: identifier,
      ...(definition.name === "message.created" || definition.name === "message.updated" ? { excludeSelf: { type: "boolean", description: "Ignore messages authored by the connected Inline user." } } : {}) },
    required: [definition.scope === "space" ? "spaceId" : "chatId"],
    additionalProperties: false,
  },
  payloadSchema: {
    type: "object",
    properties: { kind: { type: "string", enum: definition.kinds }, chatId: identifier, spaceId: identifier, messageId: identifier,
      messageIds: { type: "array", items: identifier }, userId: identifier, memberId: identifier, groupId: identifier, interactionId: identifier },
    required: ["kind", ...(definition.scope === "either" ? [] : [definition.scope === "space" ? "spaceId" : "chatId"])],
    additionalProperties: false,
  },
}))
