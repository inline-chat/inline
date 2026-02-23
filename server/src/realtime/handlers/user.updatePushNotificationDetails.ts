import {
  PushNotificationProvider,
  PushContentEncryptionKey_Algorithm,
  type UpdatePushNotificationDetailsInput,
  type UpdatePushNotificationDetailsResult,
} from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { updatePushNotificationDetails as updatePushNotificationDetailsFunction } from "@in/server/functions/user.updatePushNotificationDetails"

export const updatePushNotificationDetailsHandler = async (
  input: UpdatePushNotificationDetailsInput,
  handlerContext: HandlerContext,
): Promise<UpdatePushNotificationDetailsResult> => {
  const legacyToken = input.applePushToken?.trim()
  let pushToken = legacyToken

  if (input.notificationMethod) {
    const provider = input.notificationMethod.provider
    const method = input.notificationMethod.method

    if (provider === PushNotificationProvider.APNS && method.oneofKind === "apns") {
      pushToken = method.apns.deviceToken.trim()
    } else if (provider === PushNotificationProvider.EXPO_ANDROID && method.oneofKind === "expoAndroid") {
      pushToken = method.expoAndroid.expoPushToken.trim()
    } else {
      throw RealtimeRpcError.BadRequest()
    }
  }

  if (!pushToken) {
    throw RealtimeRpcError.BadRequest()
  }

  if (input.pushContentEncryptionKey) {
    const key = input.pushContentEncryptionKey
    if (key.publicKey.length !== 32) {
      throw RealtimeRpcError.BadRequest()
    }
    if (key.algorithm !== PushContentEncryptionKey_Algorithm.X25519_HKDF_SHA256_AES256_GCM) {
      throw RealtimeRpcError.BadRequest()
    }
  }

  await updatePushNotificationDetailsFunction(
    {
      applePushToken: pushToken,
      pushContentEncryptionKey: input.pushContentEncryptionKey
        ? {
            publicKey: input.pushContentEncryptionKey.publicKey,
            keyId: input.pushContentEncryptionKey.keyId || undefined,
            algorithm:
              input.pushContentEncryptionKey.algorithm !== PushContentEncryptionKey_Algorithm.UNSPECIFIED
                ? PushContentEncryptionKey_Algorithm[input.pushContentEncryptionKey.algorithm]
                : undefined,
          }
        : undefined,
      pushContentVersion: input.pushContentVersion !== undefined ? Number(input.pushContentVersion) : undefined,
    },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )

  return {}
}
