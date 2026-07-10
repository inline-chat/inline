import { closeDb, db, schema } from "@in/server/db"
import { ChatModel } from "@in/server/db/models/chats"
import { SessionsModel } from "@in/server/db/models/sessions"
import { messages, users } from "@in/server/db/schema"
import { loginCodes } from "@in/server/db/schema/loginCodes"
import { createChat } from "@in/server/functions/messages.createChat"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { decryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { dialogOpenDefaultsForChat } from "@in/server/modules/dialogOpen"
import { generateToken, hashLoginCode } from "@in/server/utils/auth"
import { and, desc, eq, gte } from "drizzle-orm"

const DEFAULT_CODE = "123456"
const DEFAULT_PREFIX = "matrix-inline-e2e"
const JSON_MARKER = "MATRIX_INLINE_E2E_JSON:"

type SeedUser = {
  id: number
  email: string
  token: string
  sessionId: number
}

type SeedOutput = {
  bridgeUser: SeedUser
  peerUser: SeedUser
  secondPeerUser: SeedUser
  dmChatId: number
  groupChatId: number
  seededMessages: {
    dm: string
    group: string
  }
  loginCode: string
}

async function main() {
  const [command = "help", ...args] = process.argv.slice(2)
  try {
    switch (command) {
      case "seed":
        await printJson(await seedFixture(parseArgs(args)))
        break
      case "set-login-code":
        await setLatestLoginCode(parseArgs(args))
        break
      case "wait-message":
        await waitForMessage(parseArgs(args))
        break
      case "help":
      case "--help":
      case "-h":
        printUsage()
        break
      default:
        throw new Error(`Unknown command: ${command}`)
    }
  } finally {
    await closeDb().catch(() => {})
  }
}

function printUsage() {
  console.log(`Usage:
  bun server/scripts/seed-matrix-inline-e2e.ts seed [--prefix name] [--json]
  bun server/scripts/seed-matrix-inline-e2e.ts set-login-code --email email@example.com [--code 123456]
  bun server/scripts/seed-matrix-inline-e2e.ts wait-message --chat-id 1 --text "hello" [--from-user-id 1000] [--timeout-ms 60000]
`)
}

function parseArgs(args: string[]): Record<string, string | boolean> {
  const parsed: Record<string, string | boolean> = {}
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i]!
    if (!arg.startsWith("--")) {
      throw new Error(`Unexpected argument: ${arg}`)
    }
    const key = arg.slice(2)
    const next = args[i + 1]
    if (!next || next.startsWith("--")) {
      parsed[key] = true
      continue
    }
    parsed[key] = next
    i += 1
  }
  return parsed
}

async function printJson(value: unknown) {
  console.log(`${JSON_MARKER}${JSON.stringify(value)}`)
}

async function seedFixture(args: Record<string, string | boolean>): Promise<SeedOutput> {
  const prefix = stringArg(args, "prefix") ?? `${DEFAULT_PREFIX}-${Date.now()}`
  const bridge = await createUserWithSession({
    email: `${prefix}-bridge@example.com`,
    firstName: "Bridge",
    lastName: "Runner",
    username: `${safeUsername(prefix)}bridge`,
    deviceId: `${prefix}-bridge-session`,
  })
  const peer = await createUserWithSession({
    email: `${prefix}-peer@example.com`,
    firstName: "Ada",
    lastName: "Peer",
    username: `${safeUsername(prefix)}peer`,
    deviceId: `${prefix}-peer-session`,
  })
  const secondPeer = await createUserWithSession({
    email: `${prefix}-group-peer@example.com`,
    firstName: "Lin",
    lastName: "Group",
    username: `${safeUsername(prefix)}group`,
    deviceId: `${prefix}-group-session`,
  })

  const dm = await ensureDm(bridge.id, peer.id)
  const dmSeedText = `inline e2e dm seed ${Date.now()}`
  await sendMessage(
    {
      peerId: { type: { oneofKind: "user", user: { userId: BigInt(bridge.id) } } },
      message: dmSeedText,
      randomId: BigInt(Date.now()) * 1000n + 1n,
      skipLinkProcessing: true,
    },
    { currentUserId: peer.id, currentSessionId: peer.sessionId },
  )

  const group = await createChat(
    {
      title: `Inline E2E Group ${prefix}`,
      isPublic: false,
      participants: [
        { userId: BigInt(bridge.id) },
        { userId: BigInt(peer.id) },
        { userId: BigInt(secondPeer.id) },
      ],
    },
    { currentUserId: bridge.id, currentSessionId: bridge.sessionId },
  )
  const groupChatId = Number(group.chat.id)
  const groupSeedText = `inline e2e group seed ${Date.now()}`
  await sendMessage(
    {
      peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(groupChatId) } } },
      message: groupSeedText,
      randomId: BigInt(Date.now()) * 1000n + 2n,
      skipLinkProcessing: true,
    },
    { currentUserId: peer.id, currentSessionId: peer.sessionId },
  )

  return {
    bridgeUser: bridge,
    peerUser: peer,
    secondPeerUser: secondPeer,
    dmChatId: dm.chat.id,
    groupChatId,
    seededMessages: {
      dm: dmSeedText,
      group: groupSeedText,
    },
    loginCode: DEFAULT_CODE,
  }
}

async function createUserWithSession(input: {
  email: string
  firstName: string
  lastName: string
  username: string
  deviceId: string
}): Promise<SeedUser> {
  const [user] = await db
    .insert(users)
    .values({
      email: input.email,
      firstName: input.firstName,
      lastName: input.lastName,
      username: input.username,
      emailVerified: true,
      pendingSetup: false,
      deleted: false,
    })
    .returning()
  if (!user) {
    throw new Error(`Failed to create user ${input.email}`)
  }

  const { token, tokenHash } = await generateToken(user.id)
  const session = await SessionsModel.create({
    userId: user.id,
    tokenHash,
    personalData: {
      deviceName: "matrix-inline e2e",
    },
    clientType: "api",
    deviceId: input.deviceId,
    clientVersion: "0.0.0-e2e",
  })

  return {
    id: user.id,
    email: input.email,
    token,
    sessionId: session.id,
  }
}

async function ensureDm(userA: number, userB: number) {
  const first = await ChatModel.createUserChatAndDialog({ currentUserId: userA, peerUserId: userB })
  await ChatModel.createUserChatAndDialog({ currentUserId: userB, peerUserId: userA })
  const openDefaults = dialogOpenDefaultsForChat(first.chat)
  await db
    .update(schema.dialogs)
    .set({ ...openDefaults, open: true, chatListHidden: false })
    .where(and(eq(schema.dialogs.chatId, first.chat.id), eq(schema.dialogs.userId, userA)))
  return first
}

async function setLatestLoginCode(args: Record<string, string | boolean>) {
  const email = requiredStringArg(args, "email")
  const code = stringArg(args, "code") ?? DEFAULT_CODE
  const challengeId = stringArg(args, "challenge-id")
  const rows = await db
    .select({ id: loginCodes.id, challengeId: loginCodes.challengeId })
    .from(loginCodes)
    .where(
      challengeId
        ? and(eq(loginCodes.email, email), eq(loginCodes.challengeId, challengeId), gte(loginCodes.expiresAt, new Date()))
        : and(eq(loginCodes.email, email), gte(loginCodes.expiresAt, new Date())),
    )
    .orderBy(desc(loginCodes.date), desc(loginCodes.id))
    .limit(1)

  const row = rows[0]
  if (!row) {
    throw new Error(`No active login challenge found for ${email}`)
  }

  await db
    .update(loginCodes)
    .set({
      code: null,
      codeHash: await hashLoginCode(code),
      attempts: 0,
    })
    .where(eq(loginCodes.id, row.id))

  await printJson({ ok: true, email, challengeId: row.challengeId, code })
}

async function waitForMessage(args: Record<string, string | boolean>) {
  const chatId = Number(requiredStringArg(args, "chat-id"))
  const text = requiredStringArg(args, "text")
  const fromUserIdRaw = stringArg(args, "from-user-id")
  const fromUserId = fromUserIdRaw ? Number(fromUserIdRaw) : undefined
  const timeoutMs = Number(stringArg(args, "timeout-ms") ?? "60000")
  const deadline = Date.now() + timeoutMs

  while (Date.now() < deadline) {
    const found = await findMessage({ chatId, text, fromUserId })
    if (found) {
      await printJson({ ok: true, chatId, messageId: found.messageId, fromUserId: found.fromId })
      return
    }
    await Bun.sleep(1000)
  }

  throw new Error(`Timed out waiting for Inline message in chat ${chatId} containing "${text}"`)
}

async function findMessage(input: { chatId: number; text: string; fromUserId?: number }) {
  const rows = await db
    .select({
      messageId: messages.messageId,
      fromId: messages.fromId,
      text: messages.text,
      textEncrypted: messages.textEncrypted,
      textIv: messages.textIv,
      textTag: messages.textTag,
    })
    .from(messages)
    .where(eq(messages.chatId, input.chatId))
    .orderBy(desc(messages.messageId))
    .limit(50)

  const needle = input.text.toLowerCase()
  return rows.find((row) => {
    if (input.fromUserId !== undefined && row.fromId !== input.fromUserId) return false
    const body =
      row.textEncrypted && row.textIv && row.textTag
        ? decryptMessage({ encrypted: row.textEncrypted, iv: row.textIv, authTag: row.textTag })
        : row.text ?? ""
    return body.toLowerCase().includes(needle)
  })
}

function stringArg(args: Record<string, string | boolean>, key: string): string | undefined {
  const value = args[key]
  return typeof value === "string" ? value : undefined
}

function requiredStringArg(args: Record<string, string | boolean>, key: string): string {
  const value = stringArg(args, key)
  if (!value) {
    throw new Error(`Missing required --${key}`)
  }
  return value
}

function safeUsername(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9_]/g, "").slice(0, 40)
}

const exitCode = await main()
  .then(() => 0)
  .catch((error) => {
    console.error(error instanceof Error ? error.message : error)
    return 1
  })

process.exit(exitCode)
