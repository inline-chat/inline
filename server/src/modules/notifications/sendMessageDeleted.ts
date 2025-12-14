import { Notifications } from "@in/server/modules/notifications/notifications"

type SendMessageDeletedPushNotificationToUserInput = {
  userId: number
  threadId: string
  messageIds: string[]
}

export const sendMessageDeletedPushNotificationToUser = async ({
  userId,
  threadId,
  messageIds,
}: SendMessageDeletedPushNotificationToUserInput) => {
  await Notifications.sendToUser({
    userId,
    payload: {
      kind: "message_deleted",
      threadId,
      messageIds,
    },
  })
}
