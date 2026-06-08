import type { MessageEntities, MessageEntity, MessageEntity_Type } from "@inline-chat/protocol/core"

export type EntityPolicy = "markdown" | "literalDetected" | "unsupported"

export type EntityRange = {
  start: number
  end: number
}

export type MarkdownEntity = EntityRange & {
  entity: MessageEntity
  open: string
  close: string
  raw: boolean
}

export type MarkdownText = {
  text: string
  entities: MessageEntities
}

export type PolicyRegistry = Record<MessageEntity_Type, EntityPolicy>
