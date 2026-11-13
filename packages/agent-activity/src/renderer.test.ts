import { describe, expect, test } from "bun:test"
import type { Doc } from "./doc.js"
import { ProgressRenderer, type ActivityEvent, type RenderOp } from "./renderer.js"
import type { Block, BlockText } from "./protocol.js"

const T0 = 1_700_000_000_000

function run(events: Array<[number, ActivityEvent]>, renderer = new ProgressRenderer({ folder: "/repo" })): RenderOp[] {
  return events.flatMap(([offset, event]) => renderer.apply(event, T0 + offset))
}

function text(doc: Doc, range: BlockText | undefined): string {
  if (!range) return ""
  return doc.text.slice(Number(range.offset), Number(range.offset + range.length))
}

/** Every range lies inside the text, as the server requires. */
function assertRanges(doc: Doc): void {
  const check = (range: BlockText | undefined) => {
    if (!range) return
    expect(range.offset >= 0n).toBe(true)
    expect(range.offset + range.length <= BigInt(doc.text.length)).toBe(true)
  }
  const walk = (blocks: readonly Block[]) => {
    for (const block of blocks) {
      switch (block.kind.oneofKind) {
        case "paragraph":
          check(block.kind.paragraph)
          break
        case "footer":
          check(block.kind.footer)
          break
        case "code":
          check(block.kind.code.text)
          break
        case "disclosure":
          check(block.kind.disclosure.summary)
          check(block.kind.disclosure.meta)
          walk(block.kind.disclosure.children)
          break
        case "diff":
          check(block.kind.diff.path)
          check(block.kind.diff.text)
          break
        case "steps":
          for (const step of block.kind.steps.steps) check(step.text)
          break
        default:
          break
      }
    }
  }
  walk(doc.blockContent.blocks)
}

/** Disclosure summaries, depth-first, as "summary [status] · meta". */
function outline(doc: Doc): string[] {
  const lines: string[] = []
  const walk = (blocks: readonly Block[], depth: number) => {
    for (const block of blocks) {
      const indent = "  ".repeat(depth)
      if (block.kind.oneofKind === "disclosure") {
        const disclosure = block.kind.disclosure
        const meta = text(doc, disclosure.meta)
        lines.push(`${indent}${text(doc, disclosure.summary)}${meta ? ` · ${meta}` : ""} [${disclosure.status}]`)
        walk(disclosure.children, depth + 1)
      } else if (block.kind.oneofKind === "paragraph") {
        lines.push(`${indent}¶ ${text(doc, block.kind.paragraph)}`)
      } else if (block.kind.oneofKind === "footer") {
        lines.push(`${indent}footer ${text(doc, block.kind.footer)}`)
      } else if (block.kind.oneofKind === "code") {
        lines.push(`${indent}code ${text(doc, block.kind.code.text).split("\n")[0]}`)
      } else if (block.kind.oneofKind === "diff") {
        lines.push(`${indent}diff ${text(doc, block.kind.diff.path)} +${block.kind.diff.additions} -${block.kind.diff.deletions}`)
      } else if (block.kind.oneofKind === "steps") {
        lines.push(`${indent}steps ${block.kind.steps.steps.map((step) => text(doc, step.text)).join(" | ")}`)
      }
    }
  }
  walk(doc.blockContent.blocks, 0)
  return lines
}

const last = (ops: RenderOp[]) => ops[ops.length - 1]!

describe("ProgressRenderer", () => {
  test("opens Working at the turn start with a live start time", () => {
    const ops = run([[0, { type: "turn.start" }]])
    expect(ops).toHaveLength(1)
    const op = ops[0]!
    expect(op.type).toBe("progress")
    expect(op.doc.text).toBe("Working · 1s")
    const block = op.doc.blockContent.blocks[0]!
    if (block.kind.oneofKind !== "disclosure") throw new Error("expected a disclosure")
    expect(block.kind.disclosure.kind).toBe(1)
    expect(block.kind.disclosure.initiallyOpen).toBe(true)
    expect(block.kind.disclosure.startedAt).toBe(BigInt(T0 / 1000))
    expect(text(op.doc, block.kind.disclosure.meta)).toBe("1s")
  })

  test("a turn that only answers leaves a quiet footer", () => {
    const ops = run([[0, { type: "turn.start" }], [2_400, { type: "turn.end", outcome: "success" }]])
    const end = last(ops)
    expect(end.type).toBe("end")
    expect(outline(end.doc)).toEqual(["footer Worked for 2s"])
  })

  test("commands run, finish and fold; reads explore", () => {
    const ops = run([
      [0, { type: "turn.start" }],
      [100, { type: "item", id: "r1", body: { kind: "read", path: "/repo/src/a.ts" }, state: "done" }],
      [200, { type: "item", id: "r2", body: { kind: "read", path: "/repo/src/b.ts" }, state: "done" }],
      [300, { type: "item", id: "s1", body: { kind: "search", query: "TODO", path: "/repo/src" }, state: "done" }],
      [400, { type: "item", id: "c1", body: { kind: "command", command: "bun test" } }],
    ])
    expect(outline(last(ops).doc)).toEqual([
      "Working · 1s [0]",
      "  Explored [4]",
      "    ¶ Read a.ts, b.ts",
      "    ¶ Search TODO in src",
      "  Running bun test [2]",
      "    code $ bun test",
    ])
    const more = run([
      [5_400, { type: "item", id: "c1", body: { kind: "command", command: "bun test", output: "12 pass", exitCode: 0 }, state: "done" }],
      [5_500, { type: "item", id: "c2", body: { kind: "command", command: "bun run lint", exitCode: 0 }, state: "done", durationMs: 2_000 }],
      [6_000, { type: "turn.end", outcome: "success" }],
    ], rendererAfter([
      [0, { type: "turn.start" }],
      [400, { type: "item", id: "c1", body: { kind: "command", command: "bun test" } }],
    ]))
    expect(outline(last(more).doc)).toEqual([
      "Worked for 6s [0]",
      "  Ran 2 commands · 7s [4]",
      "    Ran bun test · 5s [4]",
      "      code $ bun test",
      "      code 12 pass",
      "    Ran bun run lint · 2s [4]",
      "      code $ bun run lint",
    ])
    const ended = last(more).doc.blockContent.blocks[0]!
    if (ended.kind.oneofKind !== "disclosure") throw new Error("expected a disclosure")
    expect(ended.kind.disclosure.kind).toBe(0)
    expect(ended.kind.disclosure.initiallyOpen).toBe(false)
    expect(ended.kind.disclosure.startedAt).toBeUndefined()
  })

  test("an unfixed failure is counted; a later success of the same command is not", () => {
    const failing = run([
      [0, { type: "turn.start" }],
      [100, { type: "item", id: "c1", body: { kind: "command", command: "make", exitCode: 2 }, state: "failed", durationMs: 1_000 }],
      [3_000, { type: "turn.end", outcome: "success" }],
    ])
    expect(outline(last(failing).doc)[0]).toBe("Worked for 3s · 1 failed [0]")
    expect(outline(last(failing).doc)[1]).toBe("  Ran make · exit 2 · 1s [5]")
    const fixed = run([
      [0, { type: "turn.start" }],
      [100, { type: "item", id: "c1", body: { kind: "command", command: "make", exitCode: 2 }, state: "failed" }],
      [200, { type: "item", id: "c2", body: { kind: "command", command: "make", exitCode: 0 }, state: "done" }],
      [3_000, { type: "turn.end", outcome: "success" }],
    ])
    expect(outline(last(fixed).doc)[0]).toBe("Worked for 3s [0]")
  })

  test("stopping cancels running rows and says so", () => {
    const ops = run([
      [0, { type: "turn.start" }],
      [100, { type: "item", id: "c1", body: { kind: "command", command: "sleep 100" } }],
      [9_000, { type: "turn.end", outcome: "cancelled" }],
    ])
    expect(outline(last(ops).doc).slice(0, 2)).toEqual(["Stopped after 9s [0]", "  Ran sleep 100 · 8s [6]"])
  })

  test("a person's message mid-turn ends the message; running work carries into the next", () => {
    const renderer = new ProgressRenderer()
    const ops = run([
      [0, { type: "turn.start" }],
      [100, { type: "item", id: "t1", body: { kind: "tool", name: "memory", title: "Saved a note" }, state: "done" }],
      [200, { type: "item", id: "c1", body: { kind: "command", command: "npm install" } }],
      [4_000, { type: "split" }],
    ], renderer)
    const [end, next] = ops.slice(-2)
    expect(end!.type).toBe("end")
    expect(end!.slot).toBe(1)
    expect(outline(end!.doc)[0]).toBe("Worked for 4s [0]")
    expect(outline(end!.doc)).not.toContain("  Running npm install [2]")
    expect(next!.type).toBe("progress")
    expect(next!.slot).toBe(2)
    expect(outline(next!.doc)[1]).toBe("  Running npm install [2]")
    const after = renderer.apply({ type: "turn.end", outcome: "success" }, T0 + 6_000)
    expect(last(after).slot).toBe(2)
    expect(outline(last(after).doc)[0]).toBe("Worked for 2s [0]")
  })

  test("a split with nothing running waits for new work before opening", () => {
    const renderer = new ProgressRenderer()
    run([[0, { type: "turn.start" }], [3_000, { type: "split" }]], renderer)
    expect(renderer.isOpen).toBe(false)
    const ops = renderer.apply({ type: "item", id: "w1", body: { kind: "web", query: "weather" } }, T0 + 4_000)
    expect(ops[0]!.slot).toBe(2)
    expect(outline(ops[0]!.doc)[1]).toBe("  Searched the web for weather [2]")
  })

  test("approvals turn the row to waiting and back", () => {
    const renderer = new ProgressRenderer()
    run([[0, { type: "turn.start" }], [100, { type: "item", id: "c1", body: { kind: "command", command: "rm -rf build" } }]], renderer)
    const waiting = renderer.apply({ type: "waiting", waiting: true }, T0 + 200)
    expect(waiting[0]!.type === "progress" && waiting[0]!.urgent).toBe(true)
    expect(outline(waiting[0]!.doc)[1]).toBe("  Running rm -rf build [3]")
    const resumed = renderer.apply({ type: "waiting", waiting: false }, T0 + 300)
    expect(outline(resumed[0]!.doc)[1]).toBe("  Running rm -rf build [2]")
  })

  test("sub-agent work nests under its row", () => {
    const ops = run([
      [0, { type: "turn.start" }],
      [100, { type: "item", id: "a1", body: { kind: "agent", title: "Research pricing pages" } }],
      [200, { type: "item", id: "w1", parent: "a1", body: { kind: "web", url: "https://example.com/pricing" }, state: "done" }],
      [300, { type: "item", id: "a1", state: "done", durationMs: 30_000 }],
    ])
    expect(outline(last(ops).doc)).toEqual([
      "Working · 1s [0]",
      "  Sub-agent: Research pricing pages · 30s [4]",
      "    Read example.com/pricing [4]",
    ])
  })

  test("reasoning heads the work after it; commentary and plans render", () => {
    const ops = run([
      [0, { type: "turn.start" }],
      [100, { type: "item", id: "th1", body: { kind: "reasoning", summary: "**Checking the config**\n\nThe port is wrong." }, state: "done" }],
      [200, { type: "item", id: "e1", body: { kind: "edit", files: [{ path: "/repo/config.ts", diff: "@@ -1 +1 @@\n-port: 1\n+port: 2" }] }, state: "done" }],
      [300, { type: "commentary", text: "Fixed the port; restarting." }],
      [400, { type: "item", id: "p1", body: { kind: "plan", steps: [{ text: "Fix", status: "completed" }, { text: "Restart", status: "in_progress" }] }, state: "done" }],
    ])
    expect(outline(last(ops).doc)).toEqual([
      "Working · 1s [0]",
      "  Checking the config [4]",
      "    ¶ **Checking the config**\n\nThe port is wrong.",
      "    Edited config.ts · +1 −1 [4]",
      "      diff config.ts +1 -1",
      "    ¶ Fixed the port; restarting.",
      "    Updated plan [4]",
      "      steps Fix | Restart",
    ])
  })

  test("credentials never reach the message", () => {
    const ops = run([
      [0, { type: "turn.start" }],
      [100, { type: "item", id: "c1", body: { kind: "command", command: "curl -H 'Authorization: Bearer abcdefghijklmnop' https://user:hunter2@api.example.com?api_key=12345", output: "OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwx" }, state: "done" }],
    ])
    const doc = last(ops).doc
    expect(doc.text).not.toContain("abcdefghijklmnop")
    expect(doc.text).not.toContain("hunter2")
    expect(doc.text).not.toContain("12345")
    expect(doc.text).not.toContain("sk-proj-")
  })

  test("a message near the size limit ends and continues in a new one", () => {
    const renderer = new ProgressRenderer()
    const big = "x".repeat(1_900)
    const events: Array<[number, ActivityEvent]> = [[0, { type: "turn.start" }]]
    for (let index = 0; index < 60; index += 1) {
      events.push([index * 10 + 10, { type: "item", id: `c${index}`, body: { kind: "command", command: `step ${index}`, output: `${big}\n${index}`, exitCode: 1 }, state: "failed" }])
    }
    const ops = run(events, renderer)
    const ends = ops.filter((op) => op.type === "end")
    expect(ends.length).toBeGreaterThan(0)
    expect(outline(ends[0]!.doc)[0]).toMatch(/^Worked for \d+s · continued below/)
    const latest = last(ops)
    expect(latest.type).toBe("progress")
    expect(latest.slot).toBeGreaterThan(1)
    for (const op of ops) {
      assertRanges(op.doc)
      expect(op.doc.text.length).toBeLessThanOrEqual(100_000)
    }
  })

  test("every doc's ranges index its text", () => {
    const ops = run([
      [0, { type: "turn.start" }],
      [100, { type: "item", id: "r1", body: { kind: "read", path: "/repo/é/🚀.ts" }, state: "done" }],
      [200, { type: "item", id: "c1", body: { kind: "command", command: "echo 🚀", output: "🚀 done", exitCode: 0 }, state: "done" }],
      [300, { type: "item", id: "t1", body: { kind: "tool", name: "image_generate", title: "Generating an image 🎨", input: "{\"prompt\":\"cat\"}" }, state: "failed" }],
      [400, { type: "turn.end", outcome: "failure" }],
    ])
    for (const op of ops) assertRanges(op.doc)
    expect(outline(last(ops).doc)[0]).toBe("Failed after 1s · 1 failed [0]")
  })
})

function rendererAfter(events: Array<[number, ActivityEvent]>): ProgressRenderer {
  const renderer = new ProgressRenderer({ folder: "/repo" })
  run(events, renderer)
  return renderer
}
