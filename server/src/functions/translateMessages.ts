import { db } from "@in/server/db"
import { messages, translations } from "@in/server/db/schema"
import { eq, and, gt, desc, inArray } from "drizzle-orm"
import { encrypt } from "@in/server/modules/encryption/encryption"
import { Log } from "@in/server/utils/log"
import type { InputPeer, MessageTranslation } from "@in/protocol/core"
import {
  MessageModel,
  type ProcessedMessage,
  type ProcessedMessageAndTranslation,
  type ProcessedMessageTranslation,
  processMessageTranslation,
} from "@in/server/db/models/messages"
import type { FunctionContext } from "@in/server/functions/_types"
import { ChatModel, getChatFromPeer } from "@in/server/db/models/chats"
import { decryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { openaiClient } from "@in/server/libs/openAI"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import type { Translation } from "openai/resources/audio/translations.mjs"
import { TranslationModule } from "@in/server/modules/translation/translation"
import { TranslationModel } from "@in/server/db/models/translations"

const log = new Log("functions/translateMessages")

type TranslateMessagesFnInput = {
  peerId: InputPeer
  messageIds: number[]
  language: string
}

export async function translateMessages(
  input: TranslateMessagesFnInput,
  context: FunctionContext,
): Promise<{ translations: MessageTranslation[] }> {
  // Get chat
  const chat = await ChatModel.getChatFromInputPeer(input.peerId, context)

  // Get messages
  const msgs = await getMessagesAndTranslations({
    chatId: chat.id,
    messageIds: input.messageIds,
    translationLanguage: input.language,
  })

  log.debug("Got messages", {
    msgs: msgs.length,
  })

  // Get existing translations
  const existingTranslations = await db.query.translations.findMany({
    where: and(
      eq(translations.chatId, chat.id),
      eq(translations.language, input.language),
      inArray(translations.messageId, input.messageIds),
    ),
  })

  // Filter out messages that already have translations
  const messagesToTranslate = msgs.filter((msg) => !existingTranslations.some((t) => t.messageId === msg.messageId))

  // Nothing to translate
  if (!messagesToTranslate.length) {
    log.debug("No messages to translate")
    return {
      translations: existingTranslations.map((t) => Encoders.translation({ translation: t })),
    }
  }

  // Translate messages
  const messageTranslations = await TranslationModule.translateMessages({
    messages: messagesToTranslate,
    language: input.language,
    chat,
    actorId: context.currentUserId,
  })

  // Insert translations
  await TranslationModel.insertTranslations(messageTranslations)

  // Encode translations
  return {
    translations: messageTranslations.map((t) => Encoders.unencryptedTranslation({ translation: t })),
  }
}

// ----------------
// HELPERS
// ----------------
async function getMessagesAndTranslations(input: {
  chatId: number
  messageIds: number[]
  translationLanguage: string
}): Promise<ProcessedMessageAndTranslation[]> {
  let result = await db.query.messages.findMany({
    where: and(eq(messages.chatId, input.chatId), inArray(messages.messageId, input.messageIds)),
    orderBy: desc(messages.messageId),
    with: {
      translations: {
        where: eq(translations.language, input.translationLanguage),
      },
    },
  })

  return result.map((msg) => {
    let translation = msg.translations.find((t) => t.language === input.translationLanguage) ?? null
    return {
      ...msg,

      // Decrypt text
      text:
        msg.textEncrypted && msg.textIv && msg.textTag
          ? decryptMessage({
              encrypted: msg.textEncrypted,
              iv: msg.textIv,
              authTag: msg.textTag,
            })
          : // legacy fallback
            msg.text,

      // Get translation in language
      translation: translation ? processMessageTranslation(translation) : null,
    }
  })
}
