import {
  MessageEntity_Type,
  type MessageEntities,
  type MessageEntity,
} from "@inline-chat/protocol/core"
import {
  $createLineBreakNode,
  $createParagraphNode,
  $createTextNode,
  $getRoot,
  $isTextNode,
  type EditorState,
  type TextNode,
} from "lexical"
import { protocolId, userId } from "@inline/ids"
import {
  $createInlineMentionNode,
  $isInlineMentionNode,
} from "./InlineMentionNode"

export type InlineComposeDocument = {
  text: string
  entities?: MessageEntities
}

const plainEntity = (
  type: MessageEntity_Type,
  offset: number,
  length: number,
): MessageEntity => ({
  type,
  offset: BigInt(offset),
  length: BigInt(length),
  entity: { oneofKind: undefined },
})

const entityRanges = (
  document: InlineComposeDocument,
  start: number,
  end: number,
) =>
  (document.entities?.entities ?? []).filter((entity) => {
    const entityStart = Number(entity.offset)
    const entityEnd = entityStart + Number(entity.length)
    return entityStart <= start && entityEnd >= end
  })

export const $setInlineComposeDocument = (
  document: InlineComposeDocument,
) => {
  const root = $getRoot()
  root.clear()
  const paragraph = $createParagraphNode()
  root.append(paragraph)
  const boundaries = Array.from(
    new Set([
      0,
      document.text.length,
      ...(document.entities?.entities ?? []).flatMap((entity) => [
        Number(entity.offset),
        Number(entity.offset + entity.length),
      ]),
    ]),
  )
    .filter(
      (value) =>
        Number.isSafeInteger(value) &&
        value >= 0 &&
        value <= document.text.length,
    )
    .sort((left, right) => left - right)

  for (let index = 0; index < boundaries.length - 1; index += 1) {
    const start = boundaries[index]!
    const end = boundaries[index + 1]!
    const segment = document.text.slice(start, end)
    const ranges = entityRanges(document, start, end)
    const mention = ranges.find(
      (entity) =>
        entity.type === MessageEntity_Type.MENTION &&
        entity.entity.oneofKind === "mention",
    )
    const mentionUserId =
      mention?.entity.oneofKind === "mention"
        ? mention.entity.mention.userId
        : undefined
    const appendText = (value: string) => {
      let node: TextNode = mentionUserId != null
        ? $createInlineMentionNode(
            value,
            userId(mentionUserId),
          )
        : $createTextNode(value)
      if (ranges.some((entity) => entity.type === MessageEntity_Type.BOLD)) {
        node = node.toggleFormat("bold")
      }
      if (ranges.some((entity) => entity.type === MessageEntity_Type.ITALIC)) {
        node = node.toggleFormat("italic")
      }
      paragraph.append(node)
    }
    const parts = segment.split("\n")
    parts.forEach((part, partIndex) => {
      if (part) appendText(part)
      if (partIndex < parts.length - 1) {
        paragraph.append($createLineBreakNode())
      }
    })
  }
  paragraph.selectEnd()
}

export const inlineComposeDocument = (
  editorState: EditorState,
): InlineComposeDocument =>
  editorState.read(() => {
    const root = $getRoot()
    const text = root.getTextContent()
    const entities: MessageEntity[] = []
    let searchOffset = 0
    for (const node of root.getAllTextNodes()) {
      if (!$isTextNode(node)) continue
      const value = node.getTextContent()
      const offset = text.indexOf(value, searchOffset)
      if (offset < 0 || value.length === 0) continue
      searchOffset = offset + value.length
      if (node.hasFormat("bold")) {
        entities.push(
          plainEntity(MessageEntity_Type.BOLD, offset, value.length),
        )
      }
      if (node.hasFormat("italic")) {
        entities.push(
          plainEntity(MessageEntity_Type.ITALIC, offset, value.length),
        )
      }
      if ($isInlineMentionNode(node)) {
        entities.push({
          type: MessageEntity_Type.MENTION,
          offset: BigInt(offset),
          length: BigInt(value.length),
          entity: {
            oneofKind: "mention",
            mention: { userId: protocolId(node.getUserId()) },
          },
        })
      }
    }
    return {
      text,
      entities: entities.length > 0 ? { entities } : undefined,
    }
  })
