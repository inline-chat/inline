import { RichDirection, type RichBlock, type RichMessage } from "@inline-chat/protocol/core"
import { richTextLimits } from "@in/server/modules/message/richText"
import { cleanStreamingMarkdown } from "./outputMarkdown"

export const STREAMING_THINKING_FALLBACK = "Thinking..."
export const STREAMING_THINKING_TEXT = "Working on the response."

export type StreamingRichDraft = {
  readonly text: string
  readonly richText: RichMessage
  readonly changed: boolean
}

export function prepareStreamingRichDraft(rawText: string, lastText = ""): StreamingRichDraft | undefined {
  const cleaned = cleanStreamingMarkdown(rawText)
  if (!cleaned) {
    return undefined
  }

  const richText = buildStreamingRichText(cleaned)
  const text = richText.fallbackText
  return {
    text,
    richText,
    changed: text !== lastText,
  }
}

export function buildStreamingRichText(text: string): RichMessage {
  const visibleText = normalizeStreamingText(text)
  const visibleBlocks = streamingVisibleBlocks(visibleText)

  return {
    version: 1,
    direction: RichDirection.DIRECTION_AUTO,
    fallbackText: visibleText || STREAMING_THINKING_FALLBACK,
    blocks: [streamingThinkingBlock(), ...visibleBlocks],
  }
}

function normalizeStreamingText(text: string): string {
  const normalized = text.replace(/\r\n?/g, "\n").trim()
  if (normalized.length <= richTextLimits.maxTextLength) {
    return normalized
  }
  return `${normalized.slice(0, richTextLimits.maxTextLength - 3).trimEnd()}...`
}

function streamingVisibleBlocks(text: string): RichBlock[] {
  if (!text) {
    return []
  }

  const blocks: RichBlock[] = []
  for (const part of text.split(/\n{2,}/)) {
    if (blocks.length >= richTextLimits.maxBlocks - 1) {
      break
    }

    const value = part.trim()
    if (!value) {
      continue
    }

    blocks.push({
      blockId: `chatgpt_streaming_visible_${blocks.length}`,
      direction: RichDirection.DIRECTION_AUTO,
      block: {
        oneofKind: "paragraph",
        paragraph: {
          text: [
            {
              text: value,
              children: [],
              styles: [],
            },
          ],
        },
      },
    })
  }

  return blocks
}

function streamingThinkingBlock(): RichBlock {
  return {
    blockId: "chatgpt_streaming_thinking",
    direction: RichDirection.DIRECTION_AUTO,
    block: {
      oneofKind: "thinking",
      thinking: {
        initiallyCollapsed: true,
        blocks: [
          {
            blockId: "chatgpt_streaming_thinking_status",
            direction: RichDirection.DIRECTION_AUTO,
            block: {
              oneofKind: "paragraph",
              paragraph: {
                text: [
                  {
                    text: STREAMING_THINKING_TEXT,
                    children: [],
                    styles: [],
                  },
                ],
              },
            },
          },
        ],
      },
    },
  }
}
