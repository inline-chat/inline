import { db } from "@in/server/db"
import { messages, translations } from "@in/server/db/schema"
import { eq, and, gt, desc, inArray, lt } from "drizzle-orm"
import { decryptBinary, encrypt } from "@in/server/modules/encryption/encryption"
import { Log } from "@in/server/utils/log"
import { MessageEntities, type InputPeer, type MessageTranslation } from "@in/protocol/core"
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

const MAX_SAFE_INTEGER = Number.MAX_SAFE_INTEGER
const CONTEXT_MESSAGE_LIMIT = 5

export async function translateMessages(
  input: TranslateMessagesFnInput,
  context: FunctionContext,
): Promise<{ translations: MessageTranslation[] }> {
  try {
    // Validate message IDs
    const validMessageIds = input.messageIds.filter((id) => Number.isInteger(id) && id > 0 && id <= MAX_SAFE_INTEGER)

    if (validMessageIds.length !== input.messageIds.length) {
      log.warn("Some message IDs were invalid and were filtered out", {
        originalCount: input.messageIds.length,
        validCount: validMessageIds.length,
        invalidIds: input.messageIds.filter((id) => !Number.isInteger(id) || id <= 0 || id > MAX_SAFE_INTEGER),
      })
    }

    if (validMessageIds.length === 0) {
      throw new Error("No valid message IDs provided")
    }

    log.debug("Starting translation request", {
      messageCount: validMessageIds.length,
      language: input.language,
    })

    // Get chat
    const chat = await ChatModel.getChatFromInputPeer(input.peerId, context)
    log.debug("Retrieved chat", { chatId: chat.id })

    // Get messages
    const msgs = await getMessagesAndTranslations({
      chatId: chat.id,
      messageIds: validMessageIds,
      translationLanguage: input.language,
    })

    log.debug("Retrieved messages", {
      messageCount: msgs.length,
      requestedCount: input.messageIds.length,
    })

    // Get existing translations
    const existingTranslations = await db._query.translations.findMany({
      where: and(
        eq(translations.chatId, chat.id),
        eq(translations.language, input.language),
        inArray(translations.messageId, input.messageIds),
      ),
    })

    log.debug("Found existing translations", {
      existingCount: existingTranslations.length,
    })

    // Filter out messages that already have translations
    const messagesToTranslate = msgs.filter((msg) => !existingTranslations.some((t) => t.messageId === msg.messageId))

    // Nothing to translate
    if (!messagesToTranslate.length) {
      log.debug("No new messages to translate, returning existing translations")
      return {
        translations: existingTranslations.map((t) => Encoders.translation({ translation: t })),
      }
    }

    log.debug("Starting translation of new messages", {
      newMessagesCount: messagesToTranslate.length,
    })

    // Get context messages if we have fewer than 5 messages to translate
    let contextMessages: ProcessedMessage[] = []
    if (messagesToTranslate.length < CONTEXT_MESSAGE_LIMIT) {
      const oldestMessageId = Math.min(...messagesToTranslate.map((m) => m.messageId))
      contextMessages = await getContextMessages({
        chatId: chat.id,
        beforeMessageId: oldestMessageId,
        limit: CONTEXT_MESSAGE_LIMIT - messagesToTranslate.length,
      })

      log.debug("Retrieved context messages", {
        contextCount: contextMessages.length,
        oldestMessageId,
      })
    }

    // Translate messages
    const messageTranslations = await TranslationModule.translateMessages({
      messages: messagesToTranslate,
      contextMessages,
      language: input.language,
      chat,
      actorId: context.currentUserId,
    }).catch((error) => {
      log.error("Failed to translate messages", {
        error,
        messageCount: messagesToTranslate.length,
        language: input.language,
      })
      throw error
    })

    log.debug("Successfully translated messages", {
      translatedCount: messageTranslations.length,
    })

    // Insert translations
    await TranslationModel.insertTranslations(messageTranslations).catch((error) => {
      log.error("Failed to insert translations", {
        error,
        translationCount: messageTranslations.length,
      })
      throw error
    })

    // Combine new and existing translations
    const allTranslations = [
      ...messageTranslations.map((t) => Encoders.unencryptedTranslation({ translation: t })),
      ...existingTranslations.map((t) => Encoders.translation({ translation: t })),
    ]

    log.debug("Returning combined translations", {
      totalTranslations: allTranslations.length,
      newTranslations: messageTranslations.length,
      existingTranslations: existingTranslations.length,
    })

    return {
      translations: allTranslations,
    }
  } catch (error) {
    log.error("Failed to process translation request", {
      error,
      peerId: input.peerId,
      messageCount: input.messageIds.length,
      language: input.language,
    })
    throw error
  }
}

// ----------------
// HELPERS
// ----------------

/**
 * Get context messages for translation to provide conversation context
 */
async function getContextMessages(input: {
  chatId: number
  beforeMessageId: number
  limit: number
}): Promise<ProcessedMessage[]> {
  try {
    const result = await db._query.messages.findMany({
      where: and(eq(messages.chatId, input.chatId), lt(messages.messageId, input.beforeMessageId)),
      orderBy: desc(messages.messageId),
      limit: input.limit,
    })

    // Reverse to get chronological order (oldest first)
    result.reverse()

    return result.map((msg) => ({
      ...msg,
      // Decrypt text
      text:
        msg.textEncrypted && msg.textIv && msg.textTag
          ? decryptMessage({
              encrypted: msg.textEncrypted,
              iv: msg.textIv,
              authTag: msg.textTag,
            })
          : msg.text,

      entities:
        msg.entitiesEncrypted && msg.entitiesIv && msg.entitiesTag
          ? MessageEntities.fromBinary(
              decryptBinary({ encrypted: msg.entitiesEncrypted, iv: msg.entitiesIv, authTag: msg.entitiesTag }),
            )
          : null,
    }))
  } catch (error) {
    log.error("Failed to get context messages", {
      error,
      chatId: input.chatId,
      beforeMessageId: input.beforeMessageId,
      limit: input.limit,
    })
    // Return empty array if we can't get context messages - translation can still proceed
    return []
  }
}

async function getMessagesAndTranslations(input: {
  chatId: number
  messageIds: number[]
  translationLanguage: string
}): Promise<ProcessedMessageAndTranslation[]> {
  try {
    let result = await db._query.messages.findMany({
      where: and(eq(messages.chatId, input.chatId), inArray(messages.messageId, input.messageIds)),
      orderBy: desc(messages.messageId),
      with: {
        translations: {
          where: eq(translations.language, input.translationLanguage),
        },
      },
    })

    log.debug("Retrieved messages from database", {
      foundCount: result.length,
      requestedCount: input.messageIds.length,
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

        entities:
          msg.entitiesEncrypted && msg.entitiesIv && msg.entitiesTag
            ? MessageEntities.fromBinary(
                decryptBinary({ encrypted: msg.entitiesEncrypted, iv: msg.entitiesIv, authTag: msg.entitiesTag }),
              )
            : null,

        // Get translation in language
        translation: translation ? processMessageTranslation(translation) : null,
      }
    })
  } catch (error) {
    log.error("Failed to get messages and translations", {
      error,
      chatId: input.chatId,
      messageCount: input.messageIds.length,
    })
    throw error
  }
}
