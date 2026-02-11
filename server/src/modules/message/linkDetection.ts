import { MessageEntities, MessageEntity_Type } from "@inline-chat/protocol/core"

type DetectHasLinkInput = {
  entities?: MessageEntities | null
}

export const detectHasLink = ({ entities }: DetectHasLinkInput): boolean => {
  return (
    entities?.entities.some(
      (entity) => entity.type === MessageEntity_Type.URL || entity.type === MessageEntity_Type.TEXT_URL,
    ) ?? false
  )
}
