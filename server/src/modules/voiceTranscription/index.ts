import type { InputPeer } from "@inline-chat/protocol/core"
import type { DbFullVoice } from "@in/server/db/models/files"
import { MessageModel } from "@in/server/db/models/messages"
import type { DbMessage } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { editMessage } from "@in/server/functions/messages.editMessage"
import { Log } from "@in/server/utils/log"
import { transcribeVoiceWithOpenAI, type VoiceTranscriber } from "./openAITranscriber"
import {
  baseVoiceTranscriptionPrompt,
  buildVoiceTranscriptionPrompt,
  type VoiceTranscriptionPrompt,
} from "./prompt"

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
  buildPrompt?: typeof buildVoiceTranscriptionPrompt
}

export const VoiceTranscriptionModule = {
  schedule(input: VoiceMessageTranscriptionInput) {
    void transcribeAndEditVoiceMessage(input).catch((error) => {
      log.error("Voice transcription failed", error, {
        chatId: input.message.chatId,
        messageId: input.message.messageId,
        voiceId: input.voice.id,
        fileId: input.voice.fileId,
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

  const prompt = await safeBuildPrompt(input, deps.buildPrompt)
  log.info("Starting voice transcription", {
    chatId: input.message.chatId,
    messageId: input.message.messageId,
    voiceId: input.voice.id,
    fileId: input.voice.fileId,
    chatType: prompt.chatType,
    promptLength: prompt.prompt.length,
    participantCount: prompt.participantCount,
    includedParticipantCount: prompt.includedParticipantCount,
    hasChatTitle: prompt.hasChatTitle,
    hasSpaceName: prompt.hasSpaceName,
  })

  const text = await deps.transcribeVoice(input.voice, { prompt: prompt.prompt })
  if (!text) {
    log.warn("Voice transcription produced no text", {
      chatId: input.message.chatId,
      messageId: input.message.messageId,
      voiceId: input.voice.id,
      fileId: input.voice.fileId,
    })
    return { didEdit: false }
  }

  const latestMessage = await MessageModel.getMessage(input.message.messageId, input.message.chatId)
  if (!shouldApplyTranscript(latestMessage, input.message, input.voice)) {
    log.info("Skipping voice transcription edit: message changed before transcription completed", {
      chatId: input.message.chatId,
      messageId: input.message.messageId,
      voiceId: input.voice.id,
      fileId: input.voice.fileId,
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

  log.info("Applied voice transcription edit", {
    chatId: input.message.chatId,
    messageId: input.message.messageId,
    voiceId: input.voice.id,
    fileId: input.voice.fileId,
    transcriptLength: text.length,
  })

  return { didEdit: true, text }
}

async function safeBuildPrompt(
  input: VoiceMessageTranscriptionInput,
  buildPrompt: typeof buildVoiceTranscriptionPrompt = buildVoiceTranscriptionPrompt,
): Promise<VoiceTranscriptionPrompt> {
  try {
    return await buildPrompt(input)
  } catch (error) {
    log.warn("Failed to build voice transcription prompt context", {
      error,
      chatId: input.message.chatId,
      messageId: input.message.messageId,
      voiceId: input.voice.id,
      fileId: input.voice.fileId,
    })
    return baseVoiceTranscriptionPrompt()
  }
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
