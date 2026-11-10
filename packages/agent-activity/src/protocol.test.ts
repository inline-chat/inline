import { describe, expect, test } from "bun:test"
import { BlockDiff_Change, BlockDisclosure_ActivityKind, BlockDisclosure_Kind, BlockStatus } from "@inline-chat/protocol"
import { ActivityKindValue, BlockStatusValue, DiffChangeValue, DisclosureKindValue } from "./protocol.js"
import { resolveOutputMode } from "./mode.js"

describe("protocol mirror", () => {
  test("enum values match @inline-chat/protocol", () => {
    expect(BlockStatusValue).toEqual({
      unspecified: BlockStatus.UNSPECIFIED,
      pending: BlockStatus.PENDING,
      running: BlockStatus.RUNNING,
      waiting: BlockStatus.WAITING,
      done: BlockStatus.DONE,
      failed: BlockStatus.FAILED,
      cancelled: BlockStatus.CANCELLED,
    })
    expect(DisclosureKindValue).toEqual({ default: BlockDisclosure_Kind.DEFAULT, progress: BlockDisclosure_Kind.PROGRESS })
    expect(ActivityKindValue).toEqual({
      unspecified: BlockDisclosure_ActivityKind.UNSPECIFIED,
      reasoning: BlockDisclosure_ActivityKind.REASONING,
      explore: BlockDisclosure_ActivityKind.EXPLORE,
      read: BlockDisclosure_ActivityKind.READ,
      search: BlockDisclosure_ActivityKind.SEARCH,
      edit: BlockDisclosure_ActivityKind.EDIT,
      delete: BlockDisclosure_ActivityKind.DELETE,
      move: BlockDisclosure_ActivityKind.MOVE,
      command: BlockDisclosure_ActivityKind.COMMAND,
      web: BlockDisclosure_ActivityKind.WEB,
      tool: BlockDisclosure_ActivityKind.TOOL,
      agent: BlockDisclosure_ActivityKind.AGENT,
    })
    expect(DiffChangeValue).toEqual({
      unspecified: BlockDiff_Change.UNSPECIFIED,
      added: BlockDiff_Change.ADDED,
      modified: BlockDiff_Change.MODIFIED,
      deleted: BlockDiff_Change.DELETED,
      renamed: BlockDiff_Change.RENAMED,
    })
  })

  test("a thread's override wins over the default; unspecified is Detailed", () => {
    expect(resolveOutputMode(undefined)).toBe("detailed")
    expect(resolveOutputMode(0, 0)).toBe("detailed")
    expect(resolveOutputMode(2)).toBe("friendly")
    expect(resolveOutputMode(2, 1)).toBe("detailed")
    expect(resolveOutputMode(1, 2)).toBe("friendly")
  })
})
