import { SessionsModel } from "@in/server/db/models/sessions"
import { isProd } from "@in/server/env"
import { getApnProvider } from "@in/server/libs/apn"
import { getCachedUserName } from "@in/server/modules/cache/userNames"
import { Log } from "@in/server/utils/log"
import { Notification } from "apn"

type SendPushNotificationToUserInput = {
  userId: number
  senderUserId: number
  threadId: string
  title: string
  body: string
  subtitle?: string
  isThread?: boolean
}

const log = new Log("notifications.sendToUser")
const macOSTopic = isProd ? "chat.inline.InlineMac" : "chat.inline.InlineMac.debug"
const iOSTopic = isProd ? "chat.inline.InlineIOS" : "chat.inline.InlineIOS.debug"

export const sendPushNotificationToUser = async ({
  userId,
  senderUserId,
  threadId,
  title,
  body,
  subtitle,
  isThread = false,
}: SendPushNotificationToUserInput) => {
  try {
    // Get all sessions for the user
    const userSessions = await SessionsModel.getValidSessionsByUserId(userId)

    if (!userSessions.length) {
      return
    }

    for (const session of userSessions) {
      if (!session.applePushToken) continue
      if (session.clientType === "macos") continue

      //let topic = session.clientType === "ios" ? iOSTopic : null
      let topic = iOSTopic

      if (!topic) continue

      // Configure notification
      const notification = new Notification()
      notification.payload = {
        userId: senderUserId,
        threadId,
        isThread,
        // from?
      }
      notification.contentAvailable = true
      notification.mutableContent = true
      notification.topic = topic
      notification.threadId = threadId

      notification.sound = "default"
      notification.alert = {
        title,
        body,
        subtitle,
      }

      let apnProvider = getApnProvider()
      if (!apnProvider) {
        Log.shared.error("APN provider not found", { userId })
        continue
      }

      const sendPush = async () => {
        if (!session.applePushToken) return
        try {
          const result = await apnProvider.send(notification, session.applePushToken)
          if (result.failed.length > 0) {
            log.error("Failed to send push notification", {
              errors: result.failed.map((f) => f.response),
              userId,
              threadId,
            })
          } else {
            log.debug("Push notification sent successfully", {
              userId,
              threadId,
            })
          }
        } catch (error) {
          log.error("Error sending push notification", {
            error,
            userId,
            threadId,
          })
        }
      }

      sendPush()
    }
  } catch (error) {
    log.error("Error sending push notification", {
      error,
      userId,
      threadId,
    })
  }
}
