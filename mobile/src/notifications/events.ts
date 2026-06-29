import * as Notifications from "expo-notifications"

import { createLogger } from "@/observability/logger"

const log = createLogger("notifications.events")

let responseSub: Notifications.EventSubscription | null = null
let receivedSub: Notifications.EventSubscription | null = null

export function installNotificationListeners(): () => void {
  if (responseSub || receivedSub) {
    return uninstallNotificationListeners
  }

  receivedSub = Notifications.addNotificationReceivedListener((notification) => {
    const data = notification.request.content.data ?? {}
    log.info("Notification received while foregrounded", notificationLogData(data))
  })

  responseSub = Notifications.addNotificationResponseReceivedListener((response) => {
    const data = response.notification.request.content.data ?? {}
    log.info("Notification opened", notificationLogData(data))
  })

  return uninstallNotificationListeners
}

function uninstallNotificationListeners(): void {
  responseSub?.remove()
  receivedSub?.remove()
  responseSub = null
  receivedSub = null
}

function notificationLogData(data: Record<string, unknown>): Record<string, unknown> {
  return {
    kind: stringValue(data["kind"]),
    threadId: stringValue(data["threadId"]),
    messageId: stringValue(data["messageId"]),
  }
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined
}
