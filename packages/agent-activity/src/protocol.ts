// Wire shapes come from @inline-chat/protocol as types only, so this package
// has no runtime dependency and bundles into each plugin as-is. The enum
// values below mirror the protocol's; protocol.test.ts keeps them in step.
import type {
  Block,
  BlockContent,
  BlockDisclosure_ActivityKind,
  BlockDisclosure_Kind,
  BlockDiff_Change,
  BlockStatus,
  BlockText,
} from "@inline-chat/protocol"

export type { Block, BlockContent, BlockText }

export const BlockStatusValue = {
  unspecified: 0 as BlockStatus,
  pending: 1 as BlockStatus,
  running: 2 as BlockStatus,
  waiting: 3 as BlockStatus,
  done: 4 as BlockStatus,
  failed: 5 as BlockStatus,
  cancelled: 6 as BlockStatus,
} as const

export const DisclosureKindValue = {
  default: 0 as BlockDisclosure_Kind,
  progress: 1 as BlockDisclosure_Kind,
} as const

export const ActivityKindValue = {
  unspecified: 0 as BlockDisclosure_ActivityKind,
  reasoning: 1 as BlockDisclosure_ActivityKind,
  explore: 2 as BlockDisclosure_ActivityKind,
  read: 3 as BlockDisclosure_ActivityKind,
  search: 4 as BlockDisclosure_ActivityKind,
  edit: 5 as BlockDisclosure_ActivityKind,
  delete: 6 as BlockDisclosure_ActivityKind,
  move: 7 as BlockDisclosure_ActivityKind,
  command: 8 as BlockDisclosure_ActivityKind,
  web: 9 as BlockDisclosure_ActivityKind,
  tool: 10 as BlockDisclosure_ActivityKind,
  agent: 11 as BlockDisclosure_ActivityKind,
} as const

export const DiffChangeValue = {
  unspecified: 0 as BlockDiff_Change,
  added: 1 as BlockDiff_Change,
  modified: 2 as BlockDiff_Change,
  deleted: 3 as BlockDiff_Change,
  renamed: 4 as BlockDiff_Change,
} as const

export type ActivityKindName = keyof typeof ActivityKindValue
export type StatusName = Exclude<keyof typeof BlockStatusValue, "unspecified" | "pending"> | "none"
