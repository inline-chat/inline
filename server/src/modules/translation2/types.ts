import type { ProcessedMessage } from "@in/server/db/models/messages"
import type { DbChat } from "@in/server/db/schema"

export interface TranslationCallInput {
  messages: ProcessedMessage[]
  contextMessages?: ProcessedMessage[]
  language: string
  chat: DbChat
  actorId: number
}

export type MarkdownTranslationMessage = ProcessedMessage & {
  markdown: string
}

export interface MarkdownTranslationCallInput extends Omit<TranslationCallInput, "messages"> {
  messages: MarkdownTranslationMessage[]
}

export type MarkdownTranslation = {
  messageId: number
  markdown: string
}
