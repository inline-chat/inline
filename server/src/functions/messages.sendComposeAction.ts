import type { InputPeer, Update } from "@inline-chat/protocol/core"
import { UpdateComposeAction_ComposeAction } from "@inline-chat/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import type { FunctionContext } from "@in/server/functions/_types"
import { getUpdateGroupFromInputPeer } from "@in/server/modules/updates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { encodePeerFromInputPeer } from "@in/server/realtime/encoders/encodePeer"
import * as transientRealtime from "@in/server/modules/internalMessaging/transient"

const MAX_CONCURRENT_COMPOSE_RECIPIENTS = 32

type Input = {
  peer: InputPeer
  action?: UpdateComposeAction_ComposeAction
}

type Output = {}

export const sendComposeAction = async (input: Input, context: FunctionContext): Promise<Output> => {
  // Get the peer information - this validates the peer exists and user has access
  const chat = await ChatModel.getChatFromInputPeer(input.peer, context)

  // Get all users who should receive this update (handles DMs and threads with multiple participants)
  const updateGroup = await getUpdateGroupFromInputPeer(input.peer, { currentUserId: context.currentUserId })
  const peerForRecipient: InputPeer = updateGroup.type === "dmUsers"
    ? { type: { oneofKind: "user", user: { userId: BigInt(context.currentUserId) } } }
    : input.peer
  const action = input.action ?? UpdateComposeAction_ComposeAction.NONE
  const actionName = composeActionName(input.action)
  const recipients = updateGroup.userIds.filter((userId) => userId !== context.currentUserId)

  for (let offset = 0; offset < recipients.length; offset += MAX_CONCURRENT_COMPOSE_RECIPIENTS) {
    const batch = recipients.slice(offset, offset + MAX_CONCURRENT_COMPOSE_RECIPIENTS)
    await Promise.all(batch.map(async (userId) => {
      const update: Update = {
        update: {
          oneofKind: "updateComposeAction",
          updateComposeAction: {
            userId: BigInt(context.currentUserId),
            peerId: encodePeerFromInputPeer({ inputPeer: peerForRecipient, currentUserId: userId }),
            action,
          },
        },
      }

      await RealtimeUpdates.pushToUser(userId, [update])
      transientRealtime.publishComposeAction(userId, context.currentUserId, chat.id, actionName)
    }))
  }
  return {}
}

function composeActionName(action: UpdateComposeAction_ComposeAction | undefined):
  "none" | "typing" | "uploadingDocument" | "uploadingPhoto" | "uploadingVideo" | "recordingVoice" {
  switch (action) {
    case UpdateComposeAction_ComposeAction.TYPING: return "typing"
    case UpdateComposeAction_ComposeAction.UPLOADING_DOCUMENT: return "uploadingDocument"
    case UpdateComposeAction_ComposeAction.UPLOADING_PHOTO: return "uploadingPhoto"
    case UpdateComposeAction_ComposeAction.UPLOADING_VIDEO: return "uploadingVideo"
    case UpdateComposeAction_ComposeAction.RECORDING_VOICE: return "recordingVoice"
    default: return "none"
  }
}
