import type { MessageActionResponseUi, Update } from "@inline-chat/protocol/core"
import { UpdatesModel } from "@in/server/db/models/updates"
import { UpdateBucket } from "@in/server/db/schema"
import { db } from "@in/server/db"
import type { FunctionContext } from "@in/server/functions/_types"
import { normalizeActionResponseUi } from "@in/server/modules/message/messageActions"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"

type Input = {
  interactionId: bigint
  ui?: MessageActionResponseUi
}

type Output = Record<string, never>

export const answerMessageAction = async (input: Input, context: FunctionContext): Promise<Output> => {
  const interactionSeq = Number(input.interactionId)
  if (!Number.isSafeInteger(interactionSeq) || interactionSeq <= 0) {
    throw RealtimeRpcError.BadRequest()
  }

  const invocation = await db.query.updates.findFirst({
    where: {
      bucket: UpdateBucket.User,
      entityId: context.currentUserId,
      seq: interactionSeq,
    },
  })

  if (!invocation) {
    throw RealtimeRpcError.BadRequest()
  }

  // A message button, or a work bar control relayed to the session's bot:
  // both are answered with a toast for the person who pressed it.
  const decrypted = UpdatesModel.decrypt(invocation)
  const update = decrypted.payload.update
  const payload =
    update.oneofKind === "userMessageActionInvoked"
      ? update.userMessageActionInvoked
      : update.oneofKind === "userAgentSessionControl"
        ? update.userAgentSessionControl
        : undefined
  if (!payload) {
    throw RealtimeRpcError.BadRequest()
  }
  const normalizedUi = normalizeActionResponseUi(input.ui)
  const targetUserId = Number(payload.actorUserId)
  if (!Number.isSafeInteger(targetUserId) || targetUserId <= 0) {
    throw RealtimeRpcError.InternalError()
  }

  const userUpdate = await UserBucketUpdates.enqueue({
    userId: targetUserId,
    update: {
      oneofKind: "userMessageActionAnswered",
      userMessageActionAnswered: {
        interactionId: BigInt(interactionSeq),
        ui: normalizedUi,
      },
    },
  })

  const realtimeUpdate: Update = {
    seq: userUpdate.seq,
    date: encodeDateStrict(userUpdate.date),
    update: {
      oneofKind: "messageActionAnswered",
      messageActionAnswered: {
        interactionId: BigInt(interactionSeq),
        ui: normalizedUi,
      },
    },
  }

  RealtimeUpdates.pushToUser(targetUserId, [realtimeUpdate])

  return {}
}
