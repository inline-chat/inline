import { preparePushNotificationToUser, sendPushNotificationToUser } from "@in/server/modules/notifications/sendToUser"
import { sendMessageDeletedPushNotificationToUser } from "@in/server/modules/notifications/sendMessageDeleted"
import { sendMessagesReadUpToPushNotificationToUser } from "@in/server/modules/notifications/sendMessagesReadUpTo"

export const Notifications = {
  sendToUser: sendPushNotificationToUser,
  prepareSendToUser: preparePushNotificationToUser,
  sendMessageDeletedToUser: sendMessageDeletedPushNotificationToUser,
  sendMessagesReadUpToToUser: sendMessagesReadUpToPushNotificationToUser,
}
