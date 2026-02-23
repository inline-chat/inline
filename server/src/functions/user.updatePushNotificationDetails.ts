import type { FunctionContext } from "@in/server/functions/_types"
import { SessionsModel } from "@in/server/db/models/sessions"

type PushContentEncryptionKeyInput = {
  publicKey: Uint8Array
  keyId?: string
  algorithm?: string
}

type Input = {
  applePushToken: string
  pushContentEncryptionKey?: PushContentEncryptionKeyInput
  pushContentVersion?: number
}

export const updatePushNotificationDetails = async (input: Input, context: FunctionContext): Promise<void> => {
  await SessionsModel.updatePushNotificationDetails(context.currentSessionId, {
    applePushToken: input.applePushToken,
    pushContentEncryptionKey: input.pushContentEncryptionKey,
    pushContentVersion: input.pushContentVersion,
  })
}
