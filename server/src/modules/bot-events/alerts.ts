import { db } from "@in/server/db"
import { users } from "@in/server/db/schema"
import { eq } from "drizzle-orm"
import { sendBotEvent } from "@in/server/modules/bot-events"
import { Log } from "@in/server/utils/log"

const log = new Log("bot-events.alerts")

const ADMIN_BASE_URL = "https://admin.inline.chat"

type AlertUser = {
  id: number
  firstName: string | null
  lastName: string | null
  username: string | null
  email: string | null
  phoneNumber: string | null
}

async function getAlertUser(userId: number): Promise<AlertUser | null> {
  try {
    const user = await db
      .select({
        id: users.id,
        firstName: users.firstName,
        lastName: users.lastName,
        username: users.username,
        email: users.email,
        phoneNumber: users.phoneNumber,
      })
      .from(users)
      .where(eq(users.id, userId))
      .limit(1)
      .then(([u]) => u)

    return user ?? null
  } catch (error) {
    log.error(error, "Failed to load user for alert", { userId })
    return null
  }
}

function userLabel(user: AlertUser): string {
  const name =
    user.firstName && user.lastName
      ? `${user.firstName} ${user.lastName}`
      : user.firstName ?? user.lastName ?? null

  if (name && user.username) return `${name} (@${user.username})`
  if (name && user.email) return `${name} (${user.email})`
  if (user.username) return `@${user.username}`
  if (user.email) return user.email
  if (name) return name
  if (user.phoneNumber) return user.phoneNumber
  return "Unknown user"
}

function escapeMarkdownLinkLabel(label: string): string {
  // Keep this minimal; our link labels are typically username/email/name.
  // Removing bracket/paren characters avoids breaking `[label](url)` syntax.
  return label.replace(/[\[\]\(\)]/g, "")
}

function adminUserUrl(userId: number): string {
  return `${ADMIN_BASE_URL}/users/${userId}`
}

function adminUserLink(user: AlertUser): string {
  const label = escapeMarkdownLinkLabel(userLabel(user))
  return `[${label}](${adminUserUrl(user.id)})`
}

export const BotAlerts = {
  spaceInvite(props: { inviterUserId: number; invitedUserId: number; spaceId: number; spaceName: string | null }) {
    void (async () => {
      const [inviter, invited] = await Promise.all([getAlertUser(props.inviterUserId), getAlertUser(props.invitedUserId)])

      const inviterText = inviter ? adminUserLink(inviter) : "Someone"
      const invitedText = invited ? adminUserLink(invited) : "someone"
      const spaceName = props.spaceName ?? "Unnamed"

      sendBotEvent(`Space invite: ${inviterText} invited ${invitedText} to "${spaceName}".`)
    })()
  },

  spaceCreated(props: { creatorUserId: number; spaceId: number; spaceName: string | null; handle: string | null }) {
    void (async () => {
      const creator = await getAlertUser(props.creatorUserId)
      const creatorText = creator ? adminUserLink(creator) : "Someone"
      const spaceName = props.spaceName ?? "Unnamed"
      const handleSuffix = props.handle ? ` (@${props.handle})` : ""

      sendBotEvent(`Space created: ${creatorText} created "${spaceName}"${handleSuffix}.`)
    })()
  },

  botCreated(props: { creatorUserId: number; botUserId: number }) {
    void (async () => {
      const [creator, bot] = await Promise.all([getAlertUser(props.creatorUserId), getAlertUser(props.botUserId)])
      const creatorText = creator ? adminUserLink(creator) : "Someone"
      const botText = bot ? adminUserLink(bot) : "a bot"
      sendBotEvent(`Bot created: ${creatorText} created ${botText}.`)
    })()
  },

  logout(props: { userId: number }) {
    void (async () => {
      const user = await getAlertUser(props.userId)
      const userText = user ? adminUserLink(user) : "Someone"
      sendBotEvent(`Logout: ${userText} logged out.`)
    })()
  },
}
