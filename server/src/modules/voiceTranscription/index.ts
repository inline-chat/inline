import type { InputPeer } from "@inline-chat/protocol/core"
import type { DbFullVoice } from "@in/server/db/models/files"
import { MessageModel } from "@in/server/db/models/messages"
import type { DbMessage } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { editMessage } from "@in/server/functions/messages.editMessage"
import { Log } from "@in/server/utils/log"
import { transcribeVoiceWithOpenAI, type VoiceTranscriber } from "./openAITranscriber"
import {
  baseVoiceTranscriptionContext,
  buildVoiceTranscriptionContext,
  type VoiceTranscriptionContext,
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
  buildContext?: typeof buildVoiceTranscriptionContext
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

  const transcriptionContext = await safeBuildContext(input, deps.buildContext)
  log.info("Starting voice transcription", {
    chatId: input.message.chatId,
    messageId: input.message.messageId,
    voiceId: input.voice.id,
    fileId: input.voice.fileId,
    chatType: transcriptionContext.chatType,
    promptLength: transcriptionContext.prompt.length,
    keywordCount: transcriptionContext.keywords.length,
    languageHintCount: transcriptionContext.languages.length,
    recentTranscriptCount: transcriptionContext.recentTranscriptCount,
    participantCount: transcriptionContext.participantCount,
    includedParticipantCount: transcriptionContext.includedParticipantCount,
    hasChatTitle: transcriptionContext.hasChatTitle,
    hasSpaceName: transcriptionContext.hasSpaceName,
  })

  const text = await deps.transcribeVoice(input.voice, {
    prompt: transcriptionContext.prompt,
    keywords: transcriptionContext.keywords,
    languages: transcriptionContext.languages,
  })
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

async function safeBuildContext(
  input: VoiceMessageTranscriptionInput,
  buildContext: typeof buildVoiceTranscriptionContext = buildVoiceTranscriptionContext,
): Promise<VoiceTranscriptionContext> {
  try {
    return await buildContext(input)
  } catch (error) {
    log.warn("Failed to build voice transcription prompt context", {
      error,
      chatId: input.message.chatId,
      messageId: input.message.messageId,
      voiceId: input.voice.id,
      fileId: input.voice.fileId,
    })
    return baseVoiceTranscriptionContext()
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
