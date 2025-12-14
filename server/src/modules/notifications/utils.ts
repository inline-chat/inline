import type { SessionWithDecryptedData } from "@in/server/db/models/sessions"
import { isProd } from "@in/server/env"
import type { Notification } from "apn"

export const iOSTopic = isProd ? "chat.inline.InlineIOS" : "chat.inline.InlineIOS.debug"

export const isIOSPushSession = (session: SessionWithDecryptedData): session is SessionWithDecryptedData & {
  applePushToken: string
} => {
  return session.clientType === "ios" && !!session.applePushToken
}

export const setPushType = (notification: Notification, pushType: "alert" | "background") => {
  ;(notification as any).pushType = pushType
}

export const configureBackgroundNotification = ({
  notification,
  expirySeconds,
  collapseId,
}: {
  notification: Notification
  expirySeconds?: number
  collapseId?: string
}) => {
  notification.contentAvailable = true
  notification.priority = 5
  if (expirySeconds) notification.expiry = expirySeconds
  if (collapseId) notification.collapseId = collapseId
  setPushType(notification, "background")
}

export const configureAlertNotification = (notification: Notification) => {
  setPushType(notification, "alert")
}
