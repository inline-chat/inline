/**
 * Reactive lab: 10,000 synthetic rows in a windowed list on the real view
 * store, with two loads. See lab-model.ts for what is measured.
 *
 * Measure a production build with 4x CPU throttling. Budgets
 * (web/docs/performance.md): streaming under 4 ms scripting per update with
 * one row rendered; 60 rows a second with no frame over 32 ms.
 */

import type { RowKey } from "@inline/core-protocol"
import { useElement, useModel, useSignal } from "@inline/reactive/react"
import { countRender, createRenderCounter } from "@inline/reactive/react/testing"
import { memo, type CSSProperties } from "react"
import { createRoot } from "react-dom/client"
import { createLab, ROW_COUNT, ROW_HEIGHT, type Lab } from "./lab-model"
import "./lab.css"

const counter = createRenderCounter()

const Row = memo(function Row(props: { lab: Lab; rowKey: RowKey }) {
  countRender("row")
  const row = useSignal(props.lab.store.rowByKey(props.rowKey))
  if (row?.kind !== "message") return <div className="lab-row" />
  return (
    <div className={row.out ? "lab-row lab-row-out" : "lab-row"}>
      <span className="lab-row-id">{row.messageId}</span>
      <span className="lab-row-text">{row.text}</span>
    </div>
  )
})

function Rows(props: { lab: Lab }) {
  countRender("list")
  const keys = useSignal(props.lab.viewport.visible)
  const offset = useSignal(props.lab.viewport.offset)
  const style = { "--lab-offset": `${offset}px` } as CSSProperties
  return (
    <div className="lab-rows" style={style}>
      {keys.map((key) => (
        <Row key={key} lab={props.lab} rowKey={key} />
      ))}
    </div>
  )
}

function Viewport(props: { lab: Lab }) {
  const ref = useElement(props.lab.viewport.attach)
  const style = { "--lab-total": `${ROW_COUNT * ROW_HEIGHT}px`, "--lab-row-height": `${ROW_HEIGHT}px` } as CSSProperties
  return (
    <div className="lab-viewport" ref={ref} style={style}>
      <div className="lab-spacer">
        <Rows lab={props.lab} />
      </div>
    </div>
  )
}

function Stats(props: { lab: Lab }) {
  const stats = useSignal(props.lab.stats)
  const load = useSignal(props.lab.load)
  const ms = (value: number) => `${value.toFixed(2)} ms`
  return (
    <dl className="lab-stats">
      <dt>Load</dt>
      <dd>{load}</dd>
      <dt>Updates measured</dt>
      <dd>{stats.updates}</dd>
      <dt>Scripting per update (last / mean / p95 / max)</dt>
      <dd>
        {ms(stats.lastMs)} / {ms(stats.meanMs)} / {ms(stats.p95Ms)} / {ms(stats.maxMs)}
      </dd>
      <dt>Rows rendered (last update / max)</dt>
      <dd>
        {stats.lastRows} / {stats.maxRows}
      </dd>
      <dt>List renders (last update)</dt>
      <dd>{stats.lastLists}</dd>
      <dt>Longest frame, last second</dt>
      <dd>{ms(stats.longestFrameMs)}</dd>
    </dl>
  )
}

function LabPage() {
  const lab = useModel(() => createLab(counter))
  return (
    <main className="lab">
      <header className="lab-header">
        <h1>Reactive lab</h1>
        <p>
          {ROW_COUNT.toLocaleString()} rows on the view store. Measure a production build with 4x CPU throttling.
        </p>
        <div className="lab-actions">
          <button type="button" onClick={() => lab.start("stream")}>
            One row, 60 updates a second
          </button>
          <button type="button" onClick={() => lab.start("spread")}>
            60 different rows a second
          </button>
          <button type="button" onClick={() => lab.stop()}>
            Stop
          </button>
          <button type="button" onClick={() => lab.resetSamples()}>
            Reset numbers
          </button>
        </div>
        <Stats lab={lab} />
      </header>
      <Viewport lab={lab} />
    </main>
  )
}

const container = document.getElementById("root")
if (container) createRoot(container).render(<LabPage />)
