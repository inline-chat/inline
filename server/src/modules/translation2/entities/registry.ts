import { MessageEntity_Type } from "@inline-chat/protocol/core"
import type { EntityPolicy, PolicyRegistry } from "./types"

export const entityPolicies: PolicyRegistry = {
  [MessageEntity_Type.UNSPECIFIED]: "unsupported",
  [MessageEntity_Type.MENTION]: "markdown",
  [MessageEntity_Type.URL]: "literalDetected",
  [MessageEntity_Type.TEXT_URL]: "markdown",
  [MessageEntity_Type.EMAIL]: "literalDetected",
  [MessageEntity_Type.BOLD]: "markdown",
  [MessageEntity_Type.ITALIC]: "markdown",
  [MessageEntity_Type.USERNAME_MENTION]: "literalDetected",
  [MessageEntity_Type.CODE]: "markdown",
  [MessageEntity_Type.PRE]: "markdown",
  [MessageEntity_Type.PHONE_NUMBER]: "literalDetected",
  [MessageEntity_Type.THREAD]: "markdown",
  [MessageEntity_Type.THREAD_TITLE]: "markdown",
  [MessageEntity_Type.BOT_COMMAND]: "literalDetected",
}

export const policyFor = (type: MessageEntity_Type): EntityPolicy => {
  return entityPolicies[type] ?? "unsupported"
}
