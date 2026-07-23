import {
  AuthStore,
  BrowserAuthSessionPersistence,
  DbObjectKind,
  createIndexedDbPersistenceStore,
  messageKey,
  type Chat,
  type DbModel,
  type Dialog,
  type Message,
  type Space,
  type User,
} from "@inline/client/core"
import {
  chatId,
  dialogId,
  messageId,
  spaceId,
  userId,
} from "@inline/ids"
import { createInlineMediaCache } from "../../inline/media/cache/createInlineMediaCache"

const accountId = userId("9223372036854774101")
const denaId = userId("9223372036854774102")
const benId = userId("9223372036854774103")
const alphaChatId = chatId("9223372036854774201")
const betaChatId = chatId("9223372036854774202")
const archivedChatId = chatId("9223372036854774203")
const productSpaceId = spaceId("9223372036854774501")
const messagesPerChat = 120
const alphaMessageBase = 9_223_372_036_854_775_000n
const betaMessageBase = 9_223_372_036_854_775_200n
const archivedMessageId = messageId("9223372036854775401")
const alphaPhotoId = 9_223_372_036_854_774_901n
const alphaPhotoMediaKey = `photo:${alphaPhotoId}:d`
const alphaPhotoRemoteUrl =
  "https://api.inline.chat/file?id=product-route-photo&exp=1&sig=never-request"
const alphaPhotoPngBase64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

const inlineMessageId = (base: bigint, index: number) =>
  messageId(String(base + BigInt(index)))

const alphaMessageId = inlineMessageId(
  alphaMessageBase,
  messagesPerChat - 1,
)
const betaMessageId = inlineMessageId(
  betaMessageBase,
  messagesPerChat - 1,
)
const alphaRestoreMessageId = inlineMessageId(alphaMessageBase, 78)
const alphaPinnedMessageId = inlineMessageId(alphaMessageBase, 112)

const users: User[] = [
  {
    kind: DbObjectKind.User,
    id: accountId,
    firstName: "Mo",
    lastName: "Cached",
    username: "mo-cached",
    email: "mo.cached@inline.test",
  },
  {
    kind: DbObjectKind.User,
    id: denaId,
    firstName: "Dena",
    lastName: "Inline",
    username: "dena-cached",
  },
  {
    kind: DbObjectKind.User,
    id: benId,
    firstName: "Ben",
    lastName: "Inline",
    username: "ben-cached",
  },
]

const chats: Chat[] = [
  {
    kind: DbObjectKind.Chat,
    id: alphaChatId,
    title: "Alpha thread",
    emoji: "🪴",
    lastMsgId: alphaMessageId,
    pinnedMessageIds: [alphaPinnedMessageId],
    date: 1_784_700_120,
  },
  {
    kind: DbObjectKind.Chat,
    id: betaChatId,
    title: "Beta thread",
    emoji: "🛠️",
    lastMsgId: betaMessageId,
    date: 1_784_700_060,
  },
  {
    kind: DbObjectKind.Chat,
    id: archivedChatId,
    title: "Archived plans",
    emoji: "📦",
    lastMsgId: archivedMessageId,
    date: 1_784_699_900,
  },
]

const dialogs: Dialog[] = [
  {
    kind: DbObjectKind.Dialog,
    id: dialogId("9223372036854774301"),
    chatId: alphaChatId,
    peerThreadId: alphaChatId,
    open: true,
    unreadCount: 1,
    order: "0001",
  },
  {
    kind: DbObjectKind.Dialog,
    id: dialogId("9223372036854774302"),
    chatId: betaChatId,
    peerThreadId: betaChatId,
    open: true,
    order: "0002",
  },
  {
    kind: DbObjectKind.Dialog,
    id: dialogId("9223372036854774303"),
    chatId: archivedChatId,
    peerThreadId: archivedChatId,
    archived: true,
    open: false,
    order: "0003",
  },
]

const cachedMessageText = (
  name: "Alpha" | "Beta",
  index: number,
) => {
  if (index === messagesPerChat - 1) {
    return name === "Alpha"
      ? "First cached message"
      : "Second cached message"
  }
  const detail = index % 7 === 0
    ? " with enough Inline history detail to exercise measured message geometry"
    : ""
  return `${name} cached message ${String(index + 1).padStart(3, "0")}${detail}`
}

const alphaPhotoMedia = {
  media: {
    oneofKind: "photo" as const,
    photo: {
      photo: {
        id: alphaPhotoId,
        date: 1n,
        format: 1,
        sizes: [
          {
            type: "d",
            w: 800,
            h: 600,
            size: 68,
            cdnUrl: alphaPhotoRemoteUrl,
          },
          {
            type: "s",
            w: 40,
            h: 30,
            size: 3,
            bytes: new Uint8Array([1, 30, 40]),
          },
        ],
      },
    },
  },
}

const messages: Message[] = [
  ...Array.from({ length: messagesPerChat }, (_, index): Message => ({
    kind: DbObjectKind.Message,
    id: messageKey(
      alphaChatId,
      inlineMessageId(alphaMessageBase, index),
    ),
    messageId: inlineMessageId(alphaMessageBase, index),
    chatId: alphaChatId,
    fromId: denaId,
    message: cachedMessageText("Alpha", index),
    date: 1_784_699_000 + index,
    media: index === messagesPerChat - 1
      ? alphaPhotoMedia
      : undefined,
    replies: index === 112
      ? {
          chatId: BigInt(alphaChatId),
          replyCount: 2,
          hasUnread: false,
          recentReplierUserIds: [BigInt(denaId), BigInt(benId)],
        }
      : undefined,
  })),
  ...Array.from({ length: messagesPerChat }, (_, index): Message => ({
    kind: DbObjectKind.Message,
    id: messageKey(
      betaChatId,
      inlineMessageId(betaMessageBase, index),
    ),
    messageId: inlineMessageId(betaMessageBase, index),
    chatId: betaChatId,
    fromId: benId,
    message: cachedMessageText("Beta", index),
    date: 1_784_698_800 + index,
  })),
  {
    kind: DbObjectKind.Message,
    id: messageKey(archivedChatId, archivedMessageId),
    messageId: archivedMessageId,
    chatId: archivedChatId,
    fromId: benId,
    message: "Archived launch notes",
    date: 1_784_699_900,
  },
]

const spaces: Space[] = [
  {
    kind: DbObjectKind.Space,
    id: productSpaceId,
    name: "Cached Space",
    creator: true,
    date: 1_784_700_000,
  },
]

export const seedInlineProductRouteCache = async () => {
  const persistence = createIndexedDbPersistenceStore(
    `user-${accountId}`,
  )
  if (!persistence) {
    throw new Error("Inline product-route harness requires IndexedDB")
  }
  await persistence.open()
  const objects: DbModel[] = [
    ...users,
    ...spaces,
    ...chats,
    ...dialogs,
    ...messages,
  ]
  await persistence.write(
    objects.map((object) => ({ type: "put", object })),
  )
  await persistence.close()

  const photoBytes = Uint8Array.from(
    atob(alphaPhotoPngBase64),
    (character) => character.charCodeAt(0),
  )
  await createInlineMediaCache({ accountId }).put(
    alphaPhotoMediaKey,
    new Blob([photoBytes], { type: "image/png" }),
  )

  const auth = new AuthStore({
    storage: new BrowserAuthSessionPersistence(
      "inline-web-session",
    ),
  })
  await auth.ready
  await auth.login({
    token: "synthetic-product-route-token",
    userId: accountId,
  })
  auth.dispose()

  return {
    accountId: String(accountId),
    alphaChatId: String(alphaChatId),
    betaChatId: String(betaChatId),
    alphaPath: `/chat/chat/${alphaChatId}`,
    betaPath: `/chat/chat/${betaChatId}`,
    alphaRestoreMessageId: String(alphaRestoreMessageId),
    alphaNewestMessageId: String(alphaMessageId),
    alphaPhotoMediaKey,
    alphaPhotoRemoteUrl,
    betaNewestMessageId: String(betaMessageId),
    persistedMessagesPerChat: messagesPerChat,
  }
}

export const readInlineProductRouteAuthState = async () => {
  const auth = new AuthStore({
    storage: new BrowserAuthSessionPersistence(
      "inline-web-session",
    ),
  })
  await auth.ready
  const snapshot = auth.getSnapshot()
  const result = {
    status: snapshot.status,
    isLoggedIn:
      snapshot.token != null &&
      snapshot.currentUserId != null,
  }
  auth.dispose()
  return result
}
