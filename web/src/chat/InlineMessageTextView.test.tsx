import {
  MessageEntity_Type,
  type MessageEntity,
} from "@inline-chat/protocol/core"
import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import {
  InlineMessageTextView,
  inlineTextEntityRanges,
} from "./InlineMessageTextView"

vi.mock("@stylexjs/stylex", () => ({
  create: <T,>(styles: T) => styles,
  defineVars: <T,>(tokens: T) => tokens,
  props: () => ({}),
}))

const entity = (
  type: MessageEntity_Type,
  offset: number,
  length: number,
): MessageEntity => ({
  type,
  offset: BigInt(offset),
  length: BigInt(length),
  entity: { oneofKind: undefined },
})

afterEach(cleanup)

describe("InlineMessageTextView", () => {
  it("renders overlapping Inline bold, italic, and mention ranges", () => {
    const { container } = render(
      <InlineMessageTextView
        text="Hello Dena"
        entities={{
          entities: [
            entity(MessageEntity_Type.BOLD, 0, 10),
            entity(MessageEntity_Type.ITALIC, 6, 4),
            {
              ...entity(MessageEntity_Type.MENTION, 6, 4),
              entity: {
                oneofKind: "mention",
                mention: { userId: 7n },
              },
            },
          ],
        }}
      />,
    )

    expect(container.querySelector("strong")).toHaveTextContent(
      "Hello",
    )
    const mention = container.querySelector("[data-inline-mention]")
    expect(mention).toHaveTextContent("Dena")
    expect(mention?.querySelector("em strong")).toHaveTextContent(
      "Dena",
    )
  })

  it("rejects unsafe URLs and malformed UTF-16 ranges", () => {
    const text = "😀 click"
    const malformed = entity(MessageEntity_Type.BOLD, 1, 1)
    expect(
      inlineTextEntityRanges(text, {
        entities: [malformed],
      }),
    ).toEqual([])

    const { container } = render(
      <InlineMessageTextView
        text="click"
        entities={{
          entities: [
            {
              ...entity(MessageEntity_Type.TEXT_URL, 0, 5),
              entity: {
                oneofKind: "textUrl",
                textUrl: { url: "javascript:alert(1)" },
              },
            },
          ],
        }}
      />,
    )
    expect(container.querySelector("a")).toBeNull()
    expect(screen.getByText("click")).toBeInTheDocument()
  })
})
