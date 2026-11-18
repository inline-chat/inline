import { markKey, markOf, uniqueMarks } from "./entities"
import { entityKind, type ComposerEntity, type DocState, type Mark } from "./types"

/**
 * The render model of a document: one line per `\n`-separated line of text,
 * each a list of runs. A run is either text with a set of marks or one atom.
 * Pure, so the DOM binding's output can be checked in Node. Derived
 * entities (`url`, `email`...) are not drawn in the composer.
 */
export type Run =
  | { kind: "text"; text: string; marks: Mark[] }
  | { kind: "atom"; text: string; entity: ComposerEntity }

export type Line = {
  /** Offset of the line's first character in the document. */
  start: number
  text: string
  runs: Run[]
  /** Stable for equal content; the binding reuses a line's element while it is unchanged. */
  key: string
}

const runKey = (run: Run): string =>
  run.kind === "atom"
    ? `a${run.entity.type}|${run.entity.userId ?? run.entity.chatId ?? run.entity.groupId ?? ""}|${run.text}`
    : `t${run.marks.map(markKey).join(",")}|${run.text}`

export const lineRuns = (
  text: string,
  entities: readonly ComposerEntity[],
  start: number,
  end: number,
): Run[] => {
  if (start === end) return []
  const relevant = entities.filter(
    (e) => entityKind(e.type) !== "derived" && e.offset < end && e.offset + e.length > start,
  )
  const cuts = new Set<number>([start, end])
  for (const e of relevant) {
    if (e.offset > start) cuts.add(e.offset)
    if (e.offset + e.length < end) cuts.add(e.offset + e.length)
  }
  const points = [...cuts].sort((a, b) => a - b)
  const runs: Run[] = []
  for (let i = 0; i + 1 < points.length; i++) {
    const from = points[i]!
    const to = points[i + 1]!
    const atom = relevant.find(
      (e) => entityKind(e.type) === "atom" && e.offset <= from && to <= e.offset + e.length,
    )
    if (atom) {
      // An atom is one run even if marks cut through it (they cannot, after
      // normalization, but stay safe).
      const last = runs[runs.length - 1]
      if (last && last.kind === "atom" && last.entity === atom) {
        last.text += text.slice(from, to)
      } else {
        runs.push({ kind: "atom", text: text.slice(from, to), entity: atom })
      }
      continue
    }
    const marks = uniqueMarks(
      relevant
        .filter((e) => entityKind(e.type) === "mark" && e.offset <= from && to <= e.offset + e.length)
        .map(markOf),
    )
    const last = runs[runs.length - 1]
    if (last && last.kind === "text" && last.marks.map(markKey).join() === marks.map(markKey).join()) {
      last.text += text.slice(from, to)
    } else {
      runs.push({ kind: "text", text: text.slice(from, to), marks })
    }
  }
  return runs
}

/** Split a document into render lines. Always at least one line. */
export const docLines = (doc: Pick<DocState, "text" | "entities">): Line[] => {
  const lines: Line[] = []
  let start = 0
  for (;;) {
    const index = doc.text.indexOf("\n", start)
    const end = index === -1 ? doc.text.length : index
    const runs = lineRuns(doc.text, doc.entities, start, end)
    lines.push({ start, text: doc.text.slice(start, end), runs, key: runs.map(runKey).join("\u0001") })
    if (index === -1) break
    start = index + 1
  }
  return lines
}
