import { db } from "@in/server/db"
import * as schema from "@in/server/db/schema"
import { eq, inArray } from "drizzle-orm"
import { encryptMessage } from "@in/server/modules/encryption/encryptMessage"

console.log("⚙️ Setting up will do eval environment")

// ========== CONFIGURATION ==========
const CHAT_TEMPLATES = [
  { name: "Marketing", emoji: "🚀" },
  { name: "Engineering", emoji: "⚙️" },
  { name: "Amy Shop", emoji: "🛍️" },
  { name: "Logistic", emoji: "🚚" },
]

const CONVERSATION_PRESETS = {
  Logistic: [
    {
      from: "vladimir",
      message: `@Dena I got this email to ZONGYU@wanver.shop from Fedex. I am not able to login to the account. I need the password reset, \n\nHis email has capitals. \n\nYou need to go figure out his user ID, and we need to reset his password because we're getting billed from Fedex`,
      number: 1,
    },
    {
      from: "vladimir",
      message: `His email is "ZONGYU@wanver.shop" and I have access to it. I do't know what his user ID is. I don't know what his password is. We can reset his password if we know the user ID`,
      number: 2,
    },
    {
      from: "dena",
      message: `我聯繫一下他`,
      number: 3,
    },
  ],
}

const PRIVATE_CHAT_MESSAGES = [
  {
    from: "vladimir",
    message: `Hey Dena, I wanted to discuss the backup functionality testing we talked about earlier. I'm planning to conduct a full end-to-end test at the GS warehouse.`,
    number: 1,
  },
  {
    from: "dena",
    message: `That sounds good! What's your approach going to be? Are you thinking of testing via the Facebook test live stream page?`,
    number: 2,
  },
  {
    from: "vladimir",
    message: `Actually, I was thinking of handling the test myself for better effectiveness and coverage. The 'verydeliciousmilk' page could be useful for setup though.`,
    number: 3,
  },
  {
    from: "dena",
    message: `Makes sense. I think it's better if you take the lead on this - you know the backup processes better than anyone. What do you need from me?`,
    number: 4,
  },
  {
    from: "vladimir",
    message: `I'll be both the DRI and observer for this task. Just wanted to make sure you're aware of the plan. I'll focus specifically on the backup processes in the GS warehouse environment.`,
    number: 5,
  },
  {
    from: "dena",
    message: `Perfect. No explicit deadline right? Just as soon as practical?`,
    number: 6,
  },
  {
    from: "vladimir",
    message: `Exactly. I'll provide feedback once testing is complete. The Facebook page setup might still be useful for related testing scenarios.`,
    number: 7,
  },
  {
    from: "dena",
    message: `Sounds like a solid plan. Let me know if you need anything else or if there are any blockers.`,
    number: 8,
  },
]

// ========== UTILITIES ==========

function extractFirstName(email: string): string {
  const namePart = email.split("@")[0]?.split(".")[0] || ""
  return namePart.charAt(0).toUpperCase() + namePart.slice(1)
}

// ========== CORE FUNCTIONS ==========
async function createUsers(emails: string[]) {
  console.log("👥 Creating users...")

  const usersToCreate = emails.map((email) => ({ email }))
  const createdUsers = await db.insert(schema.users).values(usersToCreate).returning()

  // Update users with names and email verification
  for (const user of createdUsers) {
    const firstName = extractFirstName(user.email!)
    await db.update(schema.users).set({ emailVerified: true, firstName }).where(eq(schema.users.id, user.id))
    console.log(`🧚 Updated user: ${firstName} (${user.email})`)
  }

  // Return updated users
  return await db
    .select({ id: schema.users.id, email: schema.users.email, firstName: schema.users.firstName })
    .from(schema.users)
    .where(
      inArray(
        schema.users.id,
        createdUsers.map((u) => u.id),
      ),
    )
}

async function createSpace(name: string, creatorId: number) {
  console.log(`🏢 Creating space: ${name}`)
  const [space] = await db.insert(schema.spaces).values({ name, creatorId }).returning()
  return space
}

async function addMembersToSpace(spaceId: number, userIds: number[]) {
  console.log("👥 Adding members to space...")
  const membersToCreate = userIds.map((userId) => ({
    userId,
    spaceId,
    role: "member" as const,
  }))

  await db.insert(schema.members).values(membersToCreate)
  console.log(`✅ Added ${userIds.length} members to space`)
}

async function createChats(spaceId: number, userIds: number[]) {
  console.log("💬 Creating chats...")

  for (const { name, emoji } of CHAT_TEMPLATES) {
    const [chat] = await db
      .insert(schema.chats)
      .values({
        title: name,
        spaceId,
        type: "thread",
        publicThread: true,
        emoji,
      })
      .returning()

    if (!chat) {
      console.error(`Failed to create chat: ${name}`)
      continue
    }

    // Create dialogs for all users
    const dialogsToCreate = userIds.map((userId) => ({
      userId,
      chatId: chat.id,
      spaceId,
    }))

    await db.insert(schema.dialogs).values(dialogsToCreate)
    console.log(`✅ Created chat: ${name}`)
  }
}

async function insertMessages(chatId: number, messages: any[], userMap: Record<string, number>) {
  const sortedMessages = messages.sort((a, b) => b.number - a.number)
  let nextMsgId = 1

  for (const msg of sortedMessages) {
    const fromId = userMap[msg.from?.toLowerCase()]
    if (!fromId || !msg.message) continue

    const encrypted = encryptMessage(msg.message)

    await db.insert(schema.messages).values({
      chatId,
      fromId,
      messageId: nextMsgId,
      textEncrypted: encrypted.encrypted,
      textIv: encrypted.iv,
      textTag: encrypted.authTag,
      date: new Date(),
    })

    await db.update(schema.chats).set({ lastMsgId: nextMsgId }).where(eq(schema.chats.id, chatId))
    nextMsgId++
  }
}

async function populateChatsWithMessages(spaceId: number, userMap: Record<string, number>) {
  console.log("📝 Populating chats with messages...")

  const chats = await db
    .select({ id: schema.chats.id, title: schema.chats.title })
    .from(schema.chats)
    .where(eq(schema.chats.spaceId, spaceId))

  for (const chat of chats) {
    const messages = CONVERSATION_PRESETS[chat.title as keyof typeof CONVERSATION_PRESETS]
    if (messages) {
      await insertMessages(chat.id, messages, userMap)
      console.log(`✅ Added messages to ${chat.title}`)
    }
  }
}

async function createPrivateChat(user1Id: number, user2Id: number) {
  console.log("💬 Creating private chat...")

  const [chat] = await db
    .insert(schema.chats)
    .values({
      type: "private",
      date: new Date(),
      minUserId: Math.min(user1Id, user2Id),
      maxUserId: Math.max(user1Id, user2Id),
    })
    .returning()

  if (!chat) {
    throw new Error("Failed to create private chat")
  }

  const dialogsToCreate = [
    { userId: user1Id, chatId: chat.id, peerUserId: user2Id, date: new Date() },
    { userId: user2Id, chatId: chat.id, peerUserId: user1Id, date: new Date() },
  ]

  await db.insert(schema.dialogs).values(dialogsToCreate)
  console.log("✅ Created private chat")
  return chat
}

// ========== MAIN EXECUTION ==========
async function main() {
  // Create users
  const users = await createUsers([`dena@wanver.shop`, `mo@wanver.shop`, `vladimir@wanver.shop`])

  // Create space
  const firstUser = users[0]
  if (!firstUser) throw new Error("No users created")

  const space = await createSpace("wanver", firstUser.id)
  if (!space) throw new Error("Space creation failed")

  // Add members to space
  await addMembersToSpace(
    space.id,
    users.map((u) => u.id),
  )

  // Create chats
  await createChats(
    space.id,
    users.map((u) => u.id),
  )

  // Populate chats with messages
  const userMap = Object.fromEntries(users.map((u) => [u.firstName?.toLowerCase(), u.id]))
  await populateChatsWithMessages(space.id, userMap)

  // Create private chat between Dena and Vladimir
  const denaUser = users.find((u) => u.firstName?.toLowerCase() === "dena")
  const vladimirUser = users.find((u) => u.firstName?.toLowerCase() === "vladimir")

  if (denaUser && vladimirUser) {
    const privateChat = await createPrivateChat(denaUser.id, vladimirUser.id)
    if (privateChat) {
      await insertMessages(privateChat.id, PRIVATE_CHAT_MESSAGES, userMap)
      console.log("✅ Created private chat with messages")
    }
  }

  console.log("🎉 Setup complete!")
}

// Execute
main().catch(console.error)
