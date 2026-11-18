// @vitest-environment happy-dom
/**
 * Render budgets against a synthetic list on the real view store. A budget
 * that fails is a bug in the data flow, not a number to raise.
 */
import type { RowKey } from "@inline/core-protocol"
import { memo } from "react"
import { afterEach, beforeEach, describe, expect, it } from "vitest"
import { signal } from "../signals"
import { ViewStore } from "../store/view-store"
import { echoRow, message, sendText } from "../testing/rows"
import { keyOf, makePatch } from "../testing/scripted-endpoint"
import { useSignal } from "./index"
import { countRender, createRenderCounter, mount, update, type Mounted, type RenderCounter } from "./testing"

const SUB = 1

const Row = memo(function Row(props: { store: ViewStore; rowKey: RowKey }) {
  countRender(`row:${props.rowKey}`)
  const row = useSignal(props.store.rowByKey(props.rowKey))
  return <li>{row?.kind === "message" ? row.text : ""}</li>
})

function List(props: { store: ViewStore }) {
  countRender("list")
  const keys = useSignal(props.store.list(SUB))
  return (
    <ul>
      {keys.map((key) => (
        <Row key={key} store={props.store} rowKey={key} />
      ))}
    </ul>
  )
}

const rows = Array.from({ length: 50 }, (_, i) => message(1, i + 1))

let store: ViewStore
let counter: RenderCounter
let mounted: Mounted

beforeEach(() => {
  store = new ViewStore()
  store.ensureSub(SUB)
  store.applyPatch(
    makePatch(0, {
      rows: rows.map((row) => ({ op: "upsert" as const, row })),
      lists: [{ sub: SUB, op: "replace", keys: rows.map(keyOf) }],
    }),
  )
  counter = createRenderCounter()
  mounted = mount(<List store={store} />)
  expect(counter.countPrefix("row:")).toBe(50)
  counter.reset()
})

afterEach(() => {
  mounted.unmount()
  counter.dispose()
})

describe("render budgets", () => {
  it.runIf(process.env.REACT_COMPILER === "1")("runs compiled by the React Compiler in the compiler project", () => {
    expect(String(Row.type)).toMatch(/const \$ = /)
    expect(String(List)).toMatch(/const \$ = /)
  })

  it("updating one row renders exactly that row", () => {
    const target = rows[17]!
    update(() => {
      store.applyPatch(makePatch(store.revision.peek(), { rows: [{ op: "upsert", row: { ...target, text: "edited" } }] }))
    })
    expect(counter.counts()).toEqual({ [`row:${keyOf(target)}`]: 1 })
    expect(mounted.container.textContent).toContain("edited")
  })

  it("appending to the list renders the new row and not the existing ones", () => {
    const added = message(1, 51)
    update(() => {
      store.applyPatch(
        makePatch(store.revision.peek(), {
          rows: [{ op: "upsert", row: added }],
          lists: [{ sub: SUB, op: "splice", index: 50, remove: 0, insert: [keyOf(added)] }],
        }),
      )
    })
    expect(counter.counts()).toEqual({ list: 1, [`row:${keyOf(added)}`]: 1 })
  })

  it("a write of an equal value renders nothing", () => {
    const target = rows[3]!
    update(() => {
      store.applyPatch(
        makePatch(store.revision.peek(), {
          rows: [{ op: "upsert", row: { ...target } }],
          lists: [{ sub: SUB, op: "replace", keys: rows.map(keyOf) }],
        }),
      )
    })
    expect(counter.total()).toBe(0)
  })

  it("a local echo appended at the end renders only the new row, and confirming it renders nothing", () => {
    const intent = sendText(1, "9", "sent")
    const echo = echoRow(intent)
    update(() => store.addOverlay("tx", [{ row: echo, appendTo: [SUB] }]))
    expect(counter.counts()).toEqual({ list: 1, [`row:${keyOf(echo)}`]: 1 })
    counter.reset()
    update(() => {
      store.applyPatch(
        makePatch(store.revision.peek(), {
          rows: [{ op: "upsert", row: { ...echo } }],
          lists: [{ sub: SUB, op: "splice", index: 50, remove: 0, insert: [keyOf(echo)] }],
          settled: [{ tx: "tx", status: "accepted" }],
        }),
      )
    })
    expect(counter.total()).toBe(0)
  })

  it("an unrelated signal write renders nothing", () => {
    const unrelated = signal(0)
    update(() => unrelated.set(1))
    expect(counter.total()).toBe(0)
  })
})
