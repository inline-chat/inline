import { describe, expect, test } from "bun:test"
import { isBlockMathSpan, mathLimits, mathMarkdown, readMathSpan } from "./math"

describe("bounded TeX source spans", () => {
  test("recognizes inline and display delimiters without modifying TeX", () => {
    for (const [markdown, source, display] of [
      [String.raw`$\frac{a}{b}$`, String.raw`\frac{a}{b}`, false],
      [String.raw`$x_1 + \text{😀}$`, String.raw`x_1 + \text{😀}`, false],
      ["$$\nx^2\n$$", "\nx^2\n", true],
      [String.raw`$$\begin{matrix}a&b\\c&d\end{matrix}$$`, String.raw`\begin{matrix}a&b\\c&d\end{matrix}`, true],
    ] as const) {
      const span = readMathSpan(markdown, 0)
      expect(span?.end).toBe(markdown.length)
      expect(span?.display).toBe(display)
      expect(span && markdown.slice(span.contentStart, span.contentEnd)).toBe(source)
    }
  })

  test("display structure requires double-dollar syntax to own its line", () => {
    for (const [source, expected] of [
      ["$$x$$", true], ["  $$x$$  ", true], ["prefix $$x$$", false], ["$$x$$2", false], ["$x$", false],
    ] as const) {
      const start = source.indexOf("$")
      const span = readMathSpan(source, start)
      expect(span).toBeDefined()
      expect(isBlockMathSpan(source, start, span!)).toBe(expected)
    }
  })

  test("keeps currency, escaped, empty, unclosed, and ambiguous dollar runs literal", () => {
    for (const input of ["$5 and $10", "$ x$", "$x $", "$x\ny$", "$$$x$$$", "\\(\\)", "\\[  \\]", "$x", "\\(x", "$$x"]) {
      expect(readMathSpan(input, 0)).toBeUndefined()
    }
    expect(readMathSpan(String.raw`\$x$`, 1)).toBeUndefined()
    expect(readMathSpan(String.raw`\\(x\)`, 1)).toBeUndefined()
  })

  test("escaped closing punctuation stays inside the body", () => {
    const source = String.raw`x + \$5`
    const input = `$${source}$`
    const span = readMathSpan(input, 0)
    expect(span && input.slice(span.contentStart, span.contentEnd)).toBe(source)
  })

  test("enforces exact source limits without truncating formulas", () => {
    for (const display of [false, true]) {
      const limit = display ? mathLimits.displaySource : mathLimits.inlineSource
      expect(mathMarkdown("x".repeat(limit), display)).toBeDefined()
      expect(mathMarkdown("x".repeat(limit + 1), display)).toBeUndefined()
    }
  })

  test("exports exact source only when it can be read back losslessly", () => {
    const source = String.raw`\frac{a_b}{c^2} + \text{**literal**}`
    for (const display of [false, true]) {
      const markdown = mathMarkdown(source, display)!
      const span = readMathSpan(markdown, 0)!
      expect(markdown.slice(span.contentStart, span.contentEnd)).toBe(source)
    }
    expect(mathMarkdown("x$y")).toBeUndefined()
    expect(mathMarkdown("x$$y", true)).toBeUndefined()
  })
})
