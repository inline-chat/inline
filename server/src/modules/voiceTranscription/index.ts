import type { InputPeer } from "@inline-chat/protocol/core"
import type { DbFullVoice } from "@in/server/db/models/files"
import { MessageModel } from "@in/server/db/models/messages"
import type { DbMessage } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { editMessage } from "@in/server/functions/messages.editMessage"
import { Log } from "@in/server/utils/log"
import { transcribeVoiceWithOpenAI, type VoiceTranscriber } from "./openAITranscriber"

const log = new Log("modules/voiceTranscription")

export type VoiceMessageTranscriptionInput = {
  message: DbMessage
  voice: DbFullVoice
  inputPeer: InputPeer
  context: FunctionContext
}

export type VoiceMessageTranscriptionDeps = {
  transcribeVoice: VoiceTranscriber
  editText: typeof editMessage
}

export const VoiceTranscriptionModule = {
  schedule(input: VoiceMessageTranscriptionInput) {
    void transcribeAndEditVoiceMessage(input).catch((error) => {
      log.error("Voice transcription failed", {
        error,
        chatId: input.message.chatId,
        messageId: input.message.messageId,
        voiceId: input.voice.id,
      })
    })
  },

  transcribeAndEditVoiceMessage,
}

export async function transcribeAndEditVoiceMessage(
  input: VoiceMessageTranscriptionInput,
  deps: VoiceMessageTranscriptionDeps = {
    transcribeVoice: transcribeVoiceWithOpenAI,
    editText: editMessage,
  },
): Promise<{ didEdit: boolean; text?: string }> {
  if (!shouldStartTranscription(input.message, input.voice)) {
    return { didEdit: false }
  }

  const latestBeforeTranscription = await MessageModel.getMessage(input.message.messageId, input.message.chatId)
  if (!shouldApplyTranscript(latestBeforeTranscription, input.message, input.voice)) {
    return { didEdit: false }
  }

  const text = await deps.transcribeVoice(input.voice)
  if (!text) {
    return { didEdit: false }
  }

  const latestMessage = await MessageModel.getMessage(input.message.messageId, input.message.chatId)
  if (!shouldApplyTranscript(latestMessage, input.message, input.voice)) {
    log.info("Skipping voice transcription edit: message changed before transcription completed", {
      chatId: input.message.chatId,
      messageId: input.message.messageId,
      voiceId: input.voice.id,
    })
    return { didEdit: false, text }
  }

  await deps.editText(
    {
      messageId: BigInt(input.message.messageId),
      peer: input.inputPeer,
      text,
      parseMarkdown: false,
    },
    input.context,
  )

  return { didEdit: true, text }
}

function shouldStartTranscription(message: DbMessage, voice: DbFullVoice): boolean {
  if (message.mediaType !== "voice" || message.voiceId !== voice.id) {
    return false
  }

  return isBlank(message.text)
}

function shouldApplyTranscript(
  latestMessage: Awaited<ReturnType<typeof MessageModel.getMessage>>,
  originalMessage: DbMessage,
  voice: DbFullVoice,
): boolean {
  if (latestMessage.mediaType !== "voice" || latestMessage.voiceId !== voice.id) {
    return false
  }

  if ((latestMessage.rev ?? 0) !== (originalMessage.rev ?? 0)) {
    return false
  }

  return isBlank(latestMessage.text)
}

function isBlank(text: string | null | undefined): boolean {
  return !text || text.trim().length === 0
}
