import {
  GetChatTranscriptInput,
  GetChatTranscriptInput_Length,
  GetChatTranscriptInput_Media,
  GetChatTranscriptInput_Mode,
  GetChatTranscriptResult,
  GetChatTranscriptResult_StopReason,
} from "@inline-chat/protocol/core"
import { Functions } from "@in/server/functions"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"

export const getChatTranscript = async (
  input: GetChatTranscriptInput,
  handlerContext: HandlerContext,
): Promise<GetChatTranscriptResult> => {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  const result = await Functions.messages.getChatTranscript(
    {
      peerId: input.peerId,
      mode: resolveMode(input.mode),
      length: resolveLength(input.length),
      media: resolveMedia(input.media),
      beforeMessageId: input.beforeMessageId,
      limit: input.limit,
    },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )

  return {
    markdown: result.markdown,
    messageCount: result.messageCount,
    fromMessageId: result.fromMessageId === undefined ? undefined : BigInt(result.fromMessageId),
    toMessageId: result.toMessageId === undefined ? undefined : BigInt(result.toMessageId),
    hasMore: result.hasMore,
    stopReason: encodeStopReason(result.stopReason),
    expiresAt: result.expiresAt === undefined ? undefined : BigInt(result.expiresAt),
  }
}

function resolveMode(value: GetChatTranscriptInput_Mode | undefined): "humanReadable" | undefined {
  switch (value) {
    case GetChatTranscriptInput_Mode.UNSPECIFIED:
    case undefined:
      return undefined
    case GetChatTranscriptInput_Mode.HUMAN_READABLE:
      return "humanReadable"
    default:
      throw RealtimeRpcError.BadRequest()
  }
}

function resolveLength(value: GetChatTranscriptInput_Length | undefined): "concise" | undefined {
  switch (value) {
    case GetChatTranscriptInput_Length.UNSPECIFIED:
    case undefined:
      return undefined
    case GetChatTranscriptInput_Length.CONCISE:
      return "concise"
    default:
      throw RealtimeRpcError.BadRequest()
  }
}

function resolveMedia(value: GetChatTranscriptInput_Media | undefined): "included" | "excluded" | undefined {
  switch (value) {
    case GetChatTranscriptInput_Media.UNSPECIFIED:
    case undefined:
      return undefined
    case GetChatTranscriptInput_Media.INCLUDED:
      return "included"
    case GetChatTranscriptInput_Media.EXCLUDED:
      return "excluded"
    default:
      throw RealtimeRpcError.BadRequest()
  }
}

function encodeStopReason(value: "complete" | "messageLimit" | "outputLimit"): GetChatTranscriptResult_StopReason {
  switch (value) {
    case "complete":
      return GetChatTranscriptResult_StopReason.COMPLETE
    case "messageLimit":
      return GetChatTranscriptResult_StopReason.MESSAGE_LIMIT
    case "outputLimit":
      return GetChatTranscriptResult_StopReason.OUTPUT_LIMIT
  }
}
