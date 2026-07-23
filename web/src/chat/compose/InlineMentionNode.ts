import {
  $applyNodeReplacement,
  TextNode,
  type EditorConfig,
  type LexicalNode,
  type NodeKey,
  type SerializedTextNode,
  type Spread,
} from "lexical"
import type { UserID } from "@inline/ids"
import { userId } from "@inline/ids"

export type SerializedInlineMentionNode = Spread<
  { userId: string },
  SerializedTextNode
>

export class InlineMentionNode extends TextNode {
  __userId: UserID

  static override getType() {
    return "inline-mention"
  }

  static override clone(node: InlineMentionNode) {
    return new InlineMentionNode(
      node.__text,
      node.__userId,
      node.__key,
    )
  }

  static override importJSON(value: SerializedInlineMentionNode) {
    return $createInlineMentionNode(
      value.text,
      userId(BigInt(value.userId)),
    )
      .setFormat(value.format)
      .setDetail(value.detail)
      .setMode(value.mode)
      .setStyle(value.style)
  }

  constructor(text: string, exactUserId: UserID, key?: NodeKey) {
    super(text, key)
    this.__userId = exactUserId
  }

  getUserId() {
    return this.getLatest().__userId
  }

  override exportJSON(): SerializedInlineMentionNode {
    return {
      ...super.exportJSON(),
      type: "inline-mention",
      userId: String(this.__userId),
      version: 1,
    }
  }

  override createDOM(config: EditorConfig) {
    const element = super.createDOM(config)
    element.dataset.inlineMention = String(this.__userId)
    return element
  }

  override isTextEntity(): true {
    return true
  }

  override canInsertTextBefore() {
    return false
  }

  override canInsertTextAfter() {
    return false
  }
}

export const $createInlineMentionNode = (
  text: string,
  exactUserId: UserID,
) =>
  $applyNodeReplacement(
    new InlineMentionNode(text, exactUserId),
  ).setMode("segmented")

export const $isInlineMentionNode = (
  node: LexicalNode | null | undefined,
): node is InlineMentionNode => node instanceof InlineMentionNode
