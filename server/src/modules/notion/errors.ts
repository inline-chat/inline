import { APIErrorCode, APIResponseError } from "@notionhq/client"
import { InlineError } from "@in/server/types/errors"

export const NOTION_SETUP_ERROR_MESSAGES = {
  parentMissing: "No Notion parent found",
  parentNotFound: "Saved Notion parent was not found",
  legacyDatabaseSelectionAmbiguous: "Multiple data sources found for legacy database selection",
} as const

export const NOTION_ACTIONABLE_ERROR_DESCRIPTIONS = {
  parentMissing: "Select a Notion source in Space Settings before creating tasks.",
  parentNotFound: "The selected Notion source is no longer available. Re-select a Notion source in Space Settings.",
  legacyDatabaseSelectionAmbiguous:
    "This Notion source needs to be reselected in Space Settings before tasks can be created.",
} as const

const ACTIONABLE_DESCRIPTION_BY_MESSAGE: Record<string, string> = {
  [NOTION_SETUP_ERROR_MESSAGES.parentMissing]: NOTION_ACTIONABLE_ERROR_DESCRIPTIONS.parentMissing,
  [NOTION_SETUP_ERROR_MESSAGES.parentNotFound]: NOTION_ACTIONABLE_ERROR_DESCRIPTIONS.parentNotFound,
  [NOTION_SETUP_ERROR_MESSAGES.legacyDatabaseSelectionAmbiguous]:
    NOTION_ACTIONABLE_ERROR_DESCRIPTIONS.legacyDatabaseSelectionAmbiguous,
}

export function isNotionObjectNotFoundError(error: unknown): error is APIResponseError {
  return APIResponseError.isAPIResponseError(error) && error.code === APIErrorCode.ObjectNotFound
}

export function toActionableNotionInlineError(error: unknown): InlineError | null {
  if (isNotionObjectNotFoundError(error)) {
    const actionableError = new InlineError(InlineError.ApiError.BAD_REQUEST)
    actionableError.description = NOTION_ACTIONABLE_ERROR_DESCRIPTIONS.parentNotFound
    return actionableError
  }

  if (!(error instanceof Error)) {
    return null
  }

  const description = ACTIONABLE_DESCRIPTION_BY_MESSAGE[error.message]
  if (!description) {
    return null
  }

  const actionableError = new InlineError(InlineError.ApiError.BAD_REQUEST)
  actionableError.description = description
  return actionableError
}
