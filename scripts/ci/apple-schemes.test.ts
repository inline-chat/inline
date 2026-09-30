import { expect, it } from "bun:test"
import { readFileSync, readdirSync } from "node:fs"
import path from "node:path"

it("every shared scheme build and test reference resolves to an existing project target", () => {
  const project = path.resolve(import.meta.dir, "../../apple/Inline.xcodeproj")
  const source = readFileSync(path.join(project, "project.pbxproj"), "utf8")
  const targets = [...source.matchAll(/([A-F0-9]{24}) \/\*[^\n]+\*\/ = \{\s*isa = PBX(?:Native|Aggregate)Target;/g)].map((match) => match[1])
  expect(targets.length).toBeGreaterThan(0)
  const schemes = path.join(project, "xcshareddata/xcschemes")
  for (const name of readdirSync(schemes).filter((name) => name.endsWith(".xcscheme"))) {
    const scheme = readFileSync(path.join(schemes, name), "utf8")
    for (const match of scheme.matchAll(/BlueprintIdentifier\s*=\s*"([A-F0-9]{24})"/g)) {
      expect(targets, `${name}: ${match[1]} must resolve to an actual target`).toContain(match[1])
    }
  }
})
