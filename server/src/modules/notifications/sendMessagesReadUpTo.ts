import { Notifications } from "@in/server/modules/notifications/notifications"

type SendMessagesReadUpToPushNotificationToUserInput = {
  userId: number
  threadId: string
  readUpToMessageId: string
}

export const sendMessagesReadUpToPushNotificationToUser = async ({
  userId,
  threadId,
  readUpToMessageId,
}: SendMessagesReadUpToPushNotificationToUserInput) => {
  await Notifications.sendToUser({
    userId,
    payload: {
      kind: "messages_read",
      threadId,
      readUpToMessageId,
    },
  })
}
