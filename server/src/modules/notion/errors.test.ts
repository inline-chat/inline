import { describe, expect, test } from "bun:test"
import { APIErrorCode, APIResponseError } from "@notionhq/client"
import { InlineError } from "@in/server/types/errors"
import {
  NOTION_ACTIONABLE_ERROR_DESCRIPTIONS,
  NOTION_SETUP_ERROR_MESSAGES,
  toActionableNotionInlineError,
} from "./errors"

describe("toActionableNotionInlineError", () => {
  test("maps missing saved parent selection to an actionable bad request", () => {
    const error = toActionableNotionInlineError(new Error(NOTION_SETUP_ERROR_MESSAGES.parentMissing))

    expect(error).toBeInstanceOf(InlineError)
    expect(error?.type).toBe("BAD_REQUEST")
    expect(error?.description).toBe(NOTION_ACTIONABLE_ERROR_DESCRIPTIONS.parentMissing)
  })

  test("maps ambiguous legacy database selections to a reselection prompt", () => {
    const error = toActionableNotionInlineError(new Error(NOTION_SETUP_ERROR_MESSAGES.legacyDatabaseSelectionAmbiguous))

    expect(error).toBeInstanceOf(InlineError)
    expect(error?.type).toBe("BAD_REQUEST")
    expect(error?.description).toBe(NOTION_ACTIONABLE_ERROR_DESCRIPTIONS.legacyDatabaseSelectionAmbiguous)
  })

  test("maps deleted or missing Notion parents to a reselection prompt", () => {
    const error = toActionableNotionInlineError(new Error(NOTION_SETUP_ERROR_MESSAGES.parentNotFound))

    expect(error).toBeInstanceOf(InlineError)
    expect(error?.type).toBe("BAD_REQUEST")
    expect(error?.description).toBe(NOTION_ACTIONABLE_ERROR_DESCRIPTIONS.parentNotFound)
  })

  test("maps Notion object_not_found API errors to a reselection prompt", () => {
    const error = toActionableNotionInlineError(
      // Runtime constructor is inherited from the SDK's internal base class.
      new APIResponseError({
        code: APIErrorCode.ObjectNotFound,
        status: 404,
        message: "Could not find database with ID",
        headers: {},
        rawBodyText: "",
        additional_data: undefined,
        request_id: undefined,
      }),
    )

    expect(error).toBeInstanceOf(InlineError)
    expect(error?.type).toBe("BAD_REQUEST")
    expect(error?.description).toBe(NOTION_ACTIONABLE_ERROR_DESCRIPTIONS.parentNotFound)
  })

  test("does not misclassify transient Notion API failures as reselection errors", () => {
    const error = toActionableNotionInlineError(
      new APIResponseError({
        code: APIErrorCode.RateLimited,
        status: 429,
        message: "Rate limited",
        headers: {},
        rawBodyText: "",
        additional_data: undefined,
        request_id: undefined,
      }),
    )

    expect(error).toBeNull()
  })

  test("ignores unknown errors", () => {
    expect(toActionableNotionInlineError(new Error("Unknown failure"))).toBeNull()
  })
})
