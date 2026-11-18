import { describe, expect, it } from "vitest"
import { classifyInitialScripts, fileName, type ResourceFact } from "./resources"

const origin = "http://localhost:8001"
const fact = (path: string, startTime: number, name = `${origin}${path}`): ResourceFact => ({
  name,
  initiatorType: "script",
  startTime,
  transferSize: 0,
  encodedBodySize: 1000,
  decodedBodySize: 1000,
})

describe("initial scripts", () => {
  it("counts same-origin scripts started before the shell painted, without workers and demo or labs code", () => {
    const entries = [
      fact("/assets/index-Dj5M9ohB.js", 5),
      fact("/assets/Shell-DZtoFUFT.js", 40),
      fact("/appearance-boot.js", 2),
      fact("/assets/core.worker-Djs9MCA3.js", 30),
      fact("/assets/sqlite3-worker1-BiWhU4UN.js", 31),
      fact("/assets/sqlite3-k2cTanUO.wasm", 32),
      fact("/assets/connect-demo-Cz-MnST1.js", 10),
      fact("/assets/demo.worker-BujQKEQ1.js", 11),
      fact("/assets/dev-snapshot-BP-XWPgP.js", 60),
      fact("/assets/quick-search-BUJ1qe5A.js", 120),
      fact("/assets/index-2tktSdTB.css", 3),
      fact("/x.js", 4, "https://cdn.example.com/x.js"),
    ]
    const { counted, excluded } = classifyInitialScripts(entries, 100, origin)
    expect(counted.map((entry) => fileName(entry.name))).toEqual(["index-Dj5M9ohB.js", "Shell-DZtoFUFT.js", "appearance-boot.js"])
    expect(Object.fromEntries(excluded.map((entry) => [fileName(entry.name), entry.reason]))).toEqual({
      "core.worker-Djs9MCA3.js": "worker bundle",
      "sqlite3-worker1-BiWhU4UN.js": "SQLite worker",
      "connect-demo-Cz-MnST1.js": "demo only (not in production)",
      "demo.worker-BujQKEQ1.js": "worker bundle",
      "dev-snapshot-BP-XWPgP.js": "labs build only (__inlineApp)",
      "x.js": "other origin",
    })
  })

  it("ignores unparseable names", () => {
    expect(classifyInitialScripts([fact("", 1, "not a url")], 100, origin)).toEqual({ counted: [], excluded: [] })
    expect(fileName("not a url")).toBe("not a url")
  })
})
