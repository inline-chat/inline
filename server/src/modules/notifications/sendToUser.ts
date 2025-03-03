import { SessionsModel } from "@in/server/db/models/sessions"
import { isProd } from "@in/server/env"
import { getApnProvider } from "@in/server/libs/apn"
import { getCachedUserName } from "@in/server/modules/cache/userNames"
import { Log } from "@in/server/utils/log"
import { Notification } from "apn"

type SendPushNotificationToUserInput = {
  userId: number
  threadId: string
  title: string
  body: string
}

const log = new Log("notifications.sendToUser")
const macOSTopic = isProd ? "chat.inline.InlineMac" : "chat.inline.InlineMac.debug"
const iOSTopic = isProd ? "chat.inline.InlineIOS" : "chat.inline.InlineIOS.debug"

export const sendPushNotificationToUser = async ({
  userId,
  threadId,
  title,
  body,
}: SendPushNotificationToUserInput) => {
  try {
    const userName = await getCachedUserName(userId)
    if (!userName) {
      Log.shared.debug("No user name found for user", { userId })
      return
    }

    // Get all sessions for the user
    const userSessions = await SessionsModel.getValidSessionsByUserId(userId)

    if (!userSessions.length) {
      Log.shared.debug("No active sessions found for user", { userId })
      return
    }

    for (const session of userSessions) {
      if (!session.applePushToken) continue

      let topic = session.clientType === "macos" ? macOSTopic : iOSTopic

      // Configure notification
      const notification = new Notification()
      notification.payload = {
        userId,
      }
      notification.contentAvailable = true
      notification.mutableContent = true
      notification.topic = topic
      notification.threadId = threadId
      notification.sound = "default"
      notification.alert = {
        title,
        body,
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
            log.debug("Failed to send push notification", {
              errors: result.failed.map((f) => f.response),
              userId,
            })
          } else {
            log.debug("Push notification sent successfully", {
              userId,
            })
          }
        } catch (error) {
          log.debug("Error sending push notification", {
            error,
            userId,
          })
        }
      }

      sendPush()
    }
  } catch (error) {
    log.debug("Error sending push notification", {
      error,
      userId,
    })
  }
}
