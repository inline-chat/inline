import "../../styles/base.css"
import { createRoot } from "react-dom/client"
import { useRef, useState } from "react"
import { userId } from "@inline/ids"
import {
  InlineComposeEditor,
  type InlineComposeEditorHandle,
} from "../../chat/compose/InlineComposeEditor"
import type { InlineComposeDocument } from "../../chat/compose/InlineComposeDocument"

export type InlineComposeBrowserHarness = {
  document(): InlineComposeDocument
  submitted(): InlineComposeDocument[]
  clear(): void
  restore(value: InlineComposeDocument): void
}

declare global {
  interface Window {
    inlineComposeHarnessReady: Promise<InlineComposeBrowserHarness>
  }
}

let resolveHarness!: (harness: InlineComposeBrowserHarness) => void
window.inlineComposeHarnessReady =
  new Promise<InlineComposeBrowserHarness>((resolve) => {
    resolveHarness = resolve
  })

function Harness() {
  const editor = useRef<InlineComposeEditorHandle>(null)
  const valueRef = useRef<InlineComposeDocument>({ text: "" })
  const submissions = useRef<InlineComposeDocument[]>([])
  const [value, setValue] = useState<InlineComposeDocument>({ text: "" })
  const mounted = useRef(false)
  if (!mounted.current) {
    mounted.current = true
    queueMicrotask(() => {
      resolveHarness({
        document: () => editor.current?.document() ?? valueRef.current,
        submitted: () => [...submissions.current],
        clear: () => editor.current?.clear(),
        restore: (next) => setValue(next),
      })
    })
  }

  return (
    <div style={{ width: 420, margin: 40, position: "relative" }}>
      <InlineComposeEditor
        ref={editor}
        value={value}
        placeholder="Message Dena"
        mentionItems={[
          { userId: userId(7), name: "Dena Sohrabi" },
          { userId: userId(8), name: "Mo" },
        ]}
        onChange={(next) => {
          valueRef.current = next
          setValue(next)
        }}
        onSubmit={(next) => {
          submissions.current.push(next)
        }}
      />
    </div>
  )
}

const root = document.querySelector<HTMLElement>("#compose-harness-root")
if (!root) throw new Error("Inline compose harness root is missing")
createRoot(root).render(<Harness />)
