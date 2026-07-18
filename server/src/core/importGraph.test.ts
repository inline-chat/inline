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
  isForbiddenProductionRuntimeImport,
} from "../../scripts/runtimeImportPolicy"

describe("complete replacement runtime graph", () => {
  it("classifies the complete retired HTTP package family", () => {
    for (
      const packageName of [
        "elysia",
        "elysia/ws",
        "elysia-helmet",
        "elysia-rate-limit",
        "@elysiajs/cors",
        "@elysiajs/swagger",
      ]
    ) {
      expect(
        isForbiddenProductionRuntimeImport(
          packageName,
        ),
      ).toBe(true)
    }

    expect(
      isForbiddenProductionRuntimeImport(
        "effect",
      ),
    ).toBe(false)
  })

  it("contains no runtime Elysia package import", () => {
    const entrypoint = fileURLToPath(
      new URL(
        "../index.ts",
        import.meta.url,
      ),
    )
    const buildScript = `
      const forbiddenImports = [];
      const result = await Bun.build({
        entrypoints: [${JSON.stringify(entrypoint)}],
        external: ["@aws-sdk/*", "sharp"],
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
                forbiddenImports.push({
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
        forbiddenImports,
        logs: result.logs.map(String),
        success: result.success,
      }));
    `
    const result = JSON.parse(
      execFileSync(
        "bun",
        ["-e", buildScript],
        { encoding: "utf8" },
      ),
    ) as {
      readonly forbiddenImports:
        ReadonlyArray<{
          readonly importer: string
          readonly path: string
        }>
      readonly logs:
        ReadonlyArray<string>
      readonly success: boolean
    }

    expect(result.logs).toEqual([])
    expect(result.success).toBe(true)
    expect(
      result.forbiddenImports,
    ).toEqual([])
  })
})
