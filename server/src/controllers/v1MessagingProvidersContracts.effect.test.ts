import { describe, expect, it } from "@effect/vitest"
import { OpenApi } from "effect/unstable/httpapi"
import { execFileSync } from "node:child_process"
import { fileURLToPath } from "node:url"
import { makePlatformApiBase } from "../core/http/openApi"
import { V1MessagingProvidersApiGroup } from "./v1MessagingProvidersContracts.effect"

describe("Effect /v1 messaging and provider contract", () => {
  it("documents every retained route and keeps upload multipart-only", () => {
    const spec = OpenApi.fromApi(
      makePlatformApiBase("https://api.inline.chat").add(V1MessagingProvidersApiGroup),
    )
    const operations = Object.values(spec.paths).reduce(
      (count, item) =>
        count +
        Object.keys(item).filter((method) =>
          ["delete", "get", "patch", "post", "put"].includes(method),
        ).length,
      0,
    )

    expect(Object.keys(spec.paths)).toHaveLength(47)
    expect(operations).toBe(70)
    expect(spec.paths["/v1/uploadFile"]?.post).toBeDefined()
    expect(spec.paths["/v1/uploadFile"]?.get).toBeUndefined()
    expect(
      spec.paths["/v1/uploadFile"]?.post?.requestBody?.content["multipart/form-data"],
    ).toBeDefined()
    const uploadSchema = spec.components.schemas["UploadFilePayload"]
    expect(uploadSchema).toMatchObject({
      type: "object",
      required: ["type", "file"],
    })
    expect(uploadSchema?.["required"]).not.toContain("thumbnail")
    expect(spec.paths["/v1/{token}/sendMessage20250509"]?.get).toBeDefined()
    expect(
      spec.paths["/v1/sendMessage20250509"]?.post?.responses["400"]?.content?.[
        "application/json"
      ]?.schema,
    ).toBeDefined()
  })

  it("keeps the complete replacement Live import graph free of Elysia", () => {
    const entrypoint = fileURLToPath(
      new URL("./v1MessagingProvidersLive.effect.ts", import.meta.url),
    )
    const buildScript = `
      const imports = [];
      const result = await Bun.build({
        entrypoints: [${JSON.stringify(entrypoint)}],
        plugins: [{
          name: "reject-runtime-elysia",
          setup(build) {
            build.onResolve({ filter: new RegExp("^elysia(?:/|$)") }, (args) => {
              imports.push({ importer: args.importer, path: args.path });
              return { external: true, path: args.path };
            });
          },
        }],
        target: "bun",
      });
      console.log(JSON.stringify({
        imports,
        logs: result.logs.map(String),
        success: result.success,
      }));
    `
    const result = JSON.parse(
      execFileSync("bun", ["-e", buildScript], {
        encoding: "utf8",
      }),
    ) as {
      readonly imports: ReadonlyArray<unknown>
      readonly logs: ReadonlyArray<string>
      readonly success: boolean
    }

    expect(result.logs).toEqual([])
    expect(result.success).toBe(true)
    expect(result.imports).toEqual([])
  })
})
