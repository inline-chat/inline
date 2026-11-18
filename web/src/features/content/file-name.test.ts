import { describe, expect, it } from "vitest"
import { displayFileName, downloadFileName, splitFileName } from "./file-name"

const RLO = "‮"

describe("file names", () => {
  it("strips bidirectional overrides, embeddings and isolates so an extension cannot be disguised", () => {
    // Displays as "invoiceexe.pdf" with the override kept.
    expect(displayFileName(`invoice${RLO}fdp.exe`)).toBe("invoicefdp.exe")
    for (const control of ["‪", "‫", "‬", "‭", "‮", "⁦", "⁧", "⁨", "⁩"]) {
      expect(displayFileName(`a${control}b.txt`)).toBe("ab.txt")
    }
  })

  it("keeps the real extension visible after splitting a disguised long name", () => {
    const parts = splitFileName(`quarterly-report-final${RLO}fdp.exe`)
    expect(`${parts.head}${parts.tail}`).toBe("quarterly-report-finalfdp.exe")
    expect(parts.tail.endsWith(".exe")).toBe(true)
    expect(parts.head + parts.tail).not.toContain(RLO)
  })

  it("removes control characters and keeps joiners and right-to-left text", () => {
    expect(displayFileName("a\u0000b\u0007c.txt")).toBe("abc.txt")
    expect(displayFileName("گزارش.pdf")).toBe("گزارش.pdf")
    expect(displayFileName("👩‍💻 notes.md")).toBe("👩‍💻 notes.md")
  })

  it("shows something for an empty or all-control name", () => {
    expect(displayFileName("")).toBe("File")
    expect(displayFileName(`${RLO}⁦`)).toBe("File")
  })

  it("makes a download name without path separators or overrides", () => {
    expect(downloadFileName(`../..${RLO}/fdp.exe`)).toBe(".._.._fdp.exe")
    expect(downloadFileName("a\\b.txt")).toBe("a_b.txt")
    expect(downloadFileName("  ")).toBe("File")
  })
})
