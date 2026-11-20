import { ChatParticipant } from "@inline-chat/protocol/core"
import type { DbChatParticipant } from "@in/server/db/schema"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"

export function encodeChatParticipant(participant: DbChatParticipant): ChatParticipant {
  return {
    userId: BigInt(participant.userId),
    date: encodeDateStrict(participant.date),
  }
}
