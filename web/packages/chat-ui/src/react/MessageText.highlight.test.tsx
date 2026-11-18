// @vitest-environment happy-dom
import { act } from "react"
import { createRoot, type Root } from "react-dom/client"
import { renderToStaticMarkup } from "react-dom/server"
import { afterEach, beforeAll, describe, expect, it } from "vitest"
import { buildTextDocument } from "../text/build"
import type { EntityInput, HighlightRange } from "../text/types"
import { MessageText, type MessageTextClassNames } from "./MessageText"

const e = (type: EntityInput["type"], offset: number, length: number, extra: Partial<EntityInput> = {}): EntityInput =>
  ({ type, offset, length, ...extra }) as EntityInput

const text = "see https://example.com now\nnext line\n\nnpm test\n\nlast **bold** words"
const doc = buildTextDocument(text, [e("url", 4, 19), e("pre", 39, 8), e("bold", 54, 8)])

const parse = (html: string): HTMLElement => new DOMParser().parseFromString(`<body>${html}</body>`, "text/html").body

const finds = (root: HTMLElement): string[] =>
  Array.from(root.querySelectorAll('mark[data-kind="find"]'), (node) => node.textContent ?? "")

describe("MessageText highlightRanges", () => {
  const ranges: HighlightRange[] = [
    [12, 19], // inside the link
    [24, 32], // across the line break: "now\nnext"
    [43, 47], // inside the code block: "test"
    [59, 65], // across the bold edge: "d** wo"
  ]

  it("marks matches in the default variant", () => {
    const html = renderToStaticMarkup(<MessageText document={doc} highlightRanges={ranges} classNames={{ find: "f" }} />)
    const root = parse(html)
    expect(finds(root)).toEqual(["example", "now\nnext", "test", "d**", " wo"])
    const inLink = root.querySelector('a[data-kind="link"] mark[data-kind="find"]')
    expect(inLink?.textContent).toBe("example")
    expect(root.querySelector('a[data-kind="link"]')?.getAttribute("href")).toBe("https://example.com/")
    expect(root.querySelector('pre[data-kind="codeBlock"] code mark[data-kind="find"]')?.textContent).toBe("test")
    expect(root.querySelector('mark[data-kind="find"] strong[data-mark="bold"]')?.textContent).toBe("d**")
    expect(root.querySelector('mark[data-kind="find"]')?.getAttribute("class")).toBe("f")
    // Distinct from the `highlight` entity.
    expect(root.querySelector('mark[data-mark="highlight"]')).toBeNull()
  })

  it("marks matches in the inline variant, with line breaks as br", () => {
    const html = renderToStaticMarkup(<MessageText document={doc} highlightRanges={ranges} inline />)
    const root = parse(html)
    expect(finds(root)).toEqual(["example", "nownext", "test", "d**", " wo"])
    const acrossLines = root.querySelectorAll('mark[data-kind="find"]')[1]
    expect(acrossLines?.querySelectorAll("br")).toHaveLength(1)
    expect(root.querySelector('code[data-kind="codeBlock"] mark[data-kind="find"]')?.textContent).toBe("test")
    expect(root.querySelector("div, p, pre")).toBeNull()
  })

  it("renders the same markup as before without ranges", () => {
    const plain = renderToStaticMarkup(<MessageText document={doc} />)
    expect(renderToStaticMarkup(<MessageText document={doc} highlightRanges={[]} />)).toBe(plain)
    expect(renderToStaticMarkup(<MessageText document={doc} highlightRanges={[[-1, 2], [5, 999]]} />)).toBe(plain)
    expect(plain).not.toContain("find")
  })
})

describe("MessageText highlight re-renders", () => {
  beforeAll(() => {
    ;(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true
  })

  let root: Root | undefined
  let host: HTMLElement | undefined
  afterEach(() => {
    act(() => root?.unmount())
    host?.remove()
    root = undefined
    host = undefined
  })

  it("re-renders only the paragraphs whose highlights changed", () => {
    const paragraphs = buildTextDocument("First para\n\nSecond para\n\nThird para")
    // Count paragraph renders: each paragraph render reads `classNames.paragraph` once.
    let reads = 0
    const classNames: MessageTextClassNames = {}
    Object.defineProperty(classNames, "paragraph", {
      get: () => {
        reads += 1
        return "p"
      },
      enumerable: true,
    })
    host = document.createElement("div")
    document.body.append(host)
    root = createRoot(host)
    const render = (highlightRanges: HighlightRange[]) =>
      act(() => root?.render(<MessageText document={paragraphs} classNames={classNames} highlightRanges={highlightRanges} />))

    render([[0, 5]])
    expect(reads).toBe(3)
    const third = host.querySelectorAll("p")[2]

    reads = 0
    render([[0, 5]])
    expect(reads).toBe(0)

    reads = 0
    render([[12, 18]])
    // The first (highlight removed) and second (highlight added) paragraphs only.
    expect(reads).toBe(2)
    expect(host.querySelectorAll("p")[2]).toBe(third)
    expect(Array.from(host.querySelectorAll('mark[data-kind="find"]'), (node) => node.textContent)).toEqual(["Second"])
  })
})
