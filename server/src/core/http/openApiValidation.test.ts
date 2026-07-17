import { describe, expect, it } from "@effect/vitest"
import { OpenApi } from "effect/unstable/httpapi"
import {
  makePlatformApiBase,
} from "./openApi"
import { assertValidOpenApiDocument } from "./openApiValidation"

const validDocument = (): unknown =>
  OpenApi.fromApi(makePlatformApiBase("https://api.inline.chat"))

describe("assertValidOpenApiDocument", () => {
  it("accepts the generated Effect OpenAPI base", () => {
    expect(() => {
      assertValidOpenApiDocument(validDocument())
    }).not.toThrow()
  })

  it("rejects operations without declared responses", () => {
    const document = validDocument() as {
      paths: Record<string, unknown>
    }
    document.paths["/broken"] = {
      get: {
        operationId: "broken",
      },
    }

    expect(() => {
      assertValidOpenApiDocument(document, "broken document")
    }).toThrow("expected an object")
  })

  it("rejects unresolved local references", () => {
    const document = validDocument() as {
      components: {
        schemas: Record<string, unknown>
      }
    }
    document.components.schemas["Broken"] = {
      $ref: "#/components/schemas/Missing",
    }

    expect(() => {
      assertValidOpenApiDocument(document, "broken document")
    }).toThrow("unresolved local reference")
  })
})
