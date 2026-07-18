import {
  describe,
  expect,
  it,
} from "@effect/vitest"
import {
  execFileSync,
} from "node:child_process"
import {
  fileURLToPath,
} from "node:url"
import {
  FORBIDDEN_PRODUCTION_RUNTIME_IMPORT_PATTERN,
} from "../../scripts/runtimeImportPolicy"

const replacementRoots = [
  "./host.effect.ts",
  "./legacyHostAdapter.effect.ts",
  "../ws/process.effect.ts",
  "../modules/cache/userSettings.effect.ts",
  "../modules/grid/providerEffects.effect.ts",
  "../modules/monitoring/databaseHealthMonitor.effect.ts",
]

describe("realtime replacement runtime graph", () => {
  it("contains no runtime Elysia import", () => {
    const entrypoints =
      replacementRoots.map((root) =>
        fileURLToPath(
          new URL(root, import.meta.url),
        ),
      )
    const buildScript = `
      const elysiaImports = [];
      const result = await Bun.build({
        entrypoints: ${JSON.stringify(entrypoints)},
        packages: "external",
        plugins: [{
          name: "reject-runtime-elysia",
          setup(build) {
            build.onResolve(
              {
                filter: new RegExp(
                  ${JSON.stringify(FORBIDDEN_PRODUCTION_RUNTIME_IMPORT_PATTERN)},
                ),
              },
              (args) => {
                elysiaImports.push({
                  importer: args.importer,
                  path: args.path,
                });
                return {
                  external: true,
                  path: args.path,
                };
              },
            );
          },
        }],
        target: "bun",
      });
      console.log(JSON.stringify({
        elysiaImports,
        logs: result.logs.map(String),
        success: result.success,
      }));
    `
    const result = JSON.parse(
      execFileSync(
        "bun",
        ["-e", buildScript],
        {
          encoding: "utf8",
        },
      ),
    ) as {
      readonly elysiaImports: ReadonlyArray<{
        readonly importer: string
        readonly path: string
      }>
      readonly logs: ReadonlyArray<string>
      readonly success: boolean
    }

    expect(
      result.logs.map(String),
    ).toEqual([])
    expect(result.success).toBe(true)
    expect(result.elysiaImports).toEqual([])
  })
})
