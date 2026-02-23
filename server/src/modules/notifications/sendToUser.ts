import { SessionsModel } from "@in/server/db/models/sessions"
import { getApnProvider } from "@in/server/libs/apn"
import { isSuppressedApnFailure, shouldInvalidateTokenForApnFailure, summarizeApnFailure } from "@in/server/libs/apnFailures"
import { Log } from "@in/server/utils/log"
import { Notification } from "apn"
import { configureAlertNotification, configureBackgroundNotification, iOSTopic, isIOSPushSession } from "./utils"
import {
  encryptSendMessagePushContent,
  PUSH_CONTENT_ALGORITHM,
  PUSH_CONTENT_VERSION,
} from "@in/server/modules/notifications/pushContentEncryption"

type AlertPushPayload = {
  kind: "alert"
  senderUserId: number
  threadId: string
  title: string
  body: string
  subtitle?: string
  isThread?: boolean
  threadEmoji?: string
}

type SendMessagePushPayload = {
  kind: "send_message"
  senderUserId: number
  threadId: string
  title: string
  body: string
  subtitle?: string
  isThread?: boolean
  messageId: string
  isUrgentNudge?: boolean
  senderDisplayName?: string
  senderProfilePhotoUrl?: string
  threadEmoji?: string
}

type MessageDeletedPushPayload = {
  kind: "message_deleted"
  threadId: string
  messageIds: string[]
}

type MessagesReadUpToPushPayload = {
  kind: "messages_read"
  threadId: string
  readUpToMessageId: string
}

export type PushToUserPayload =
  | AlertPushPayload
  | SendMessagePushPayload
  | MessageDeletedPushPayload
  | MessagesReadUpToPushPayload

type SendPushToUserInput = {
  userId: number
  payload: PushToUserPayload
}

const log = new Log("notifications.sendToUser")

type ApsOverrides = {
  ["interruption-level"]?: "time-sensitive"
}

const configureTimeSensitive = (notification: Notification) => {
  const aps = notification.aps as unknown as ApsOverrides
  aps["interruption-level"] = "time-sensitive"
}

const configurePlaintextSendMessageNotification = ({
  notification,
  payload,
}: {
  notification: Notification
  payload: SendMessagePushPayload
}) => {
  const senderPayload: Record<string, unknown> = { id: payload.senderUserId }

  if (payload.senderDisplayName) senderPayload["displayName"] = payload.senderDisplayName
  if (payload.senderProfilePhotoUrl) senderPayload["profilePhotoUrl"] = payload.senderProfilePhotoUrl

  const apsPayload: Record<string, unknown> = {
    userId: payload.senderUserId,
    threadId: payload.threadId,
    isThread: payload.isThread ?? false,
    sender: senderPayload,
    threadEmoji: payload.threadEmoji,
    messageId: payload.messageId,
  }

  notification.payload = apsPayload
  notification.contentAvailable = true
  notification.mutableContent = true
  configureAlertNotification(notification)

  notification.sound = "default"
  if (payload.isUrgentNudge) {
    configureTimeSensitive(notification)
  }
  notification.alert = {
    title: payload.title,
    body: payload.body,
    subtitle: payload.subtitle,
  }
}

const genericEncryptedAlertTitle = "New message"
const genericEncryptedAlertBody = "Open Inline to read it."

type UserSession = Awaited<ReturnType<typeof SessionsModel.getValidSessionsByUserId>>[number]

const sessionSupportsEncryptedPushContent = (
  session: UserSession,
): session is UserSession & {
  pushContentKeyPublic: Uint8Array
  pushContentVersion: number
  pushContentKeyAlgorithm: string
} => {
  if (!session.pushContentKeyPublic || session.pushContentKeyPublic.length === 0) return false
  if (!session.pushContentVersion || session.pushContentVersion < PUSH_CONTENT_VERSION) return false
  return session.pushContentKeyAlgorithm === PUSH_CONTENT_ALGORITHM
}

export const sendPushNotificationToUser = async ({ userId, payload }: SendPushToUserInput) => {
  try {
    // Get all sessions for the user
    const userSessions = await SessionsModel.getValidSessionsByUserId(userId)

    if (!userSessions.length) {
      return
    }

    const apnProvider = getApnProvider()
    if (!apnProvider) {
      Log.shared.error("APN provider not found", { userId })
      return
    }

    for (const session of userSessions.filter(isIOSPushSession)) {
      const topic = iOSTopic
      if (!topic) continue

      const notification = new Notification()
      notification.topic = topic
      notification.threadId = payload.threadId

      if (payload.kind === "send_message") {
        if (sessionSupportsEncryptedPushContent(session)) {
          let encryptedContent: ReturnType<typeof encryptSendMessagePushContent> | undefined
          try {
            encryptedContent = encryptSendMessagePushContent({
              recipientPublicKey: session.pushContentKeyPublic,
              recipientKeyId: session.pushContentKeyId ?? undefined,
              content: {
                kind: "send_message",
                sender: {
                  id: payload.senderUserId,
                  displayName: payload.senderDisplayName,
                  profilePhotoUrl: payload.senderProfilePhotoUrl,
                },
                title: payload.title,
                body: payload.body,
                subtitle: payload.subtitle,
                threadId: payload.threadId,
                messageId: payload.messageId,
                isThread: payload.isThread ?? false,
                threadEmoji: payload.threadEmoji,
              },
            })
          } catch (error) {
            log.error("Failed to encrypt push content", {
              error,
              userId,
              sessionId: session.id,
              threadId: payload.threadId,
            })
          }

          if (encryptedContent) {
            notification.payload = {
              kind: "send_message_encrypted",
              threadId: payload.threadId,
              messageId: payload.messageId,
              encryptedContent,
            }
            notification.contentAvailable = true
            notification.mutableContent = true
            configureAlertNotification(notification)

            notification.sound = "default"
            if (payload.isUrgentNudge) {
              configureTimeSensitive(notification)
            }

            notification.alert = {
              title: genericEncryptedAlertTitle,
              body: genericEncryptedAlertBody,
            }
          } else {
            configurePlaintextSendMessageNotification({ notification, payload })
          }
        } else {
          configurePlaintextSendMessageNotification({ notification, payload })
        }
      } else if (payload.kind === "alert") {
        notification.payload = {
          kind: "alert",
          userId: payload.senderUserId,
          threadId: payload.threadId,
          isThread: payload.isThread ?? false,
          threadEmoji: payload.threadEmoji,
        }

        notification.contentAvailable = true
        notification.mutableContent = false
        configureAlertNotification(notification)

        notification.sound = "default"
        notification.alert = {
          title: payload.title,
          body: payload.body,
          subtitle: payload.subtitle,
        }
      } else if (payload.kind === "message_deleted") {
        if (!payload.messageIds.length) continue
        configureBackgroundNotification({
          notification,
          expirySeconds: Math.floor(Date.now() / 1000) + 60 * 60,
        })
        notification.payload = {
          kind: "message_deleted",
          threadId: payload.threadId,
          messageIds: payload.messageIds,
        }
      } else if (payload.kind === "messages_read") {
        if (!payload.readUpToMessageId) continue
        const collapseId = `messages_read:${payload.threadId}`
        configureBackgroundNotification({
          notification,
          expirySeconds: Math.floor(Date.now() / 1000) + 60 * 10,
          collapseId,
        })
        notification.payload = {
          kind: "messages_read",
          threadId: payload.threadId,
          readUpToMessageId: payload.readUpToMessageId,
        }
      } else {
        continue
      }

      const sendPush = async () => {
        if (!session.applePushToken) return
        try {
          const result = await apnProvider.send(notification, session.applePushToken)
          if (result.failed.length > 0) {
            const summaries = result.failed.map((failure) => summarizeApnFailure(failure))
            const suppressed = summaries.filter((s) => isSuppressedApnFailure(s))
            const important = summaries.filter((s) => !isSuppressedApnFailure(s))

            if (important.length) {
              log.warn("Failed to send push notification", {
                failures: important,
                suppressedFailureCount: suppressed.length,
                userId,
                sessionId: session.id,
                threadId: payload.threadId,
              })
            } else {
              log.debug("Failed to send push notification (expected)", {
                failures: suppressed,
                userId,
                sessionId: session.id,
                threadId: payload.threadId,
              })
            }

            if (summaries.some((s) => shouldInvalidateTokenForApnFailure(s))) {
              try {
                await SessionsModel.clearApplePushToken(session.id)
              } catch (error) {
                log.debug("Failed to clear invalid push token", { error, userId, sessionId: session.id })
              }
            }
          } else {
            log.debug("Push notification sent successfully", {
              userId,
              threadId: payload.threadId,
            })
          }
        } catch (error) {
          log.error("Error sending push notification", {
            error,
            userId,
            threadId: payload.threadId,
          })
        }
      }

      sendPush()
    }
  } catch (error) {
    log.error("Error sending push notification", {
      error,
      userId,
      threadId: payload.threadId,
    })
  }
}
