/**
 * External task cards (`ExternalTaskAttachmentView.swift`): a headline with the
 * person's name, an empty checkbox and the title. The Mac shows no status,
 * number or app icon; the model carries them for later.
 */

import type { ExternalTaskAttachment, ExternalTaskStatus } from "@inline/core-protocol"
import type { UserID } from "@inline/ids"
import { safeLink, type WebLink } from "../links"

export type ExternalTaskModel = {
  readonly key: string
  /** Whose name goes in the headline; undefined shows "Unassigned". */
  readonly userId: UserID | undefined
  readonly phrase: "createdLinearIssue" | "willDo" | "unassigned"
  /** "Untitled" when empty. */
  readonly title: string
  readonly status: ExternalTaskStatus | undefined
  readonly number: string | undefined
  readonly application: string
  /** The task's page; undefined when the URL is not a safe web link. */
  readonly link: WebLink | undefined
  readonly height: number
}

export const externalTaskModel = (task: ExternalTaskAttachment): ExternalTaskModel => {
  const link = safeLink(task.url)
  const linear = task.application.trim().toLowerCase() === "linear"
  return {
    key: `task:${task.id}`,
    userId: task.assigneeUserId,
    phrase: task.assigneeUserId === undefined ? "unassigned" : linear ? "createdLinearIssue" : "willDo",
    title: task.title.trim().length > 0 ? task.title : "Untitled",
    status: task.status,
    number: task.number,
    application: task.application,
    link: link?.kind === "web" ? link : undefined,
    height: 46,
  }
}

/** "Ada created a Linear issue", "Ada will do", "Unassigned". `name` is the user's display name. */
export const externalTaskHeadline = (model: ExternalTaskModel, name: string): string => {
  switch (model.phrase) {
    case "createdLinearIssue":
      return `${name} created a Linear issue`
    case "willDo":
      return `${name} will do`
    case "unassigned":
      return "Unassigned"
  }
}
