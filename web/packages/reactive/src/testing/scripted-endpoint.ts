/**
 * A core endpoint a test drives by hand: it records every command the UI
 * posts and delivers whatever core messages the test hands it. It speaks the
 * `CoreEndpoint` contract from @inline/core-protocol and nothing more.
 */

import type { Command, CoreEndpoint, CoreMessage, CoreMessageListener, Patch, Row, RowKey } from "@inline/core-protocol"
import { rowKey } from "@inline/core-protocol"

export interface ScriptedEndpoint extends CoreEndpoint {
  readonly posted: Command[]
  deliver(message: CoreMessage): void
  /** Deliver a patch on top of the last revision this endpoint delivered. */
  patch(parts: Partial<Omit<Patch, "base" | "revision">> & { base?: number; revision?: number }): Patch
  /** Commands of one kind, in order. */
  commands<K extends Command["kind"]>(kind: K): Extract<Command, { kind: K }>[]
  closed(): boolean
}

export const scriptedEndpoint = (): ScriptedEndpoint => {
  const listeners = new Set<CoreMessageListener>()
  const posted: Command[] = []
  let revision = 0
  let isClosed = false
  const deliver = (message: CoreMessage) => {
    if (message.kind === "patch") revision = message.patch.revision
    if (message.kind === "snapshot") revision = message.snapshot.revision
    for (const listener of listeners) listener(message)
  }
  return {
    posted,
    post: (command) => {
      posted.push(command)
    },
    subscribe: (listener) => {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
    close: () => {
      isClosed = true
      listeners.clear()
    },
    closed: () => isClosed,
    deliver,
    patch: (parts) => {
      const base = parts.base ?? revision
      const patch: Patch = {
        base,
        revision: parts.revision ?? base + 1,
        rows: parts.rows ?? [],
        lists: parts.lists ?? [],
        resources: parts.resources ?? [],
        settled: parts.settled ?? [],
      }
      deliver({ kind: "patch", patch })
      return patch
    },
    commands: (kind) => posted.filter((command) => command.kind === kind) as never,
  }
}

/** A patch that applies to `base`, with defaults for the parts not given. */
export const makePatch = (base: number, parts: Partial<Omit<Patch, "base">> = {}): Patch => ({
  base,
  revision: parts.revision ?? base + 1,
  rows: parts.rows ?? [],
  lists: parts.lists ?? [],
  resources: parts.resources ?? [],
  settled: parts.settled ?? [],
})

export const keyOf = (row: Row): RowKey => rowKey(row.kind, row.id)
