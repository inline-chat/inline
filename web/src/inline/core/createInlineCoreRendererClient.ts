import type {
  AuthSession,
  AuthStore,
} from "@inline/client/core"
import { InlineCoreRendererClient } from "./InlineCoreRendererClient"
import { activeInlineCoreSharedWorkerName } from "./InlineCoreSharedWorkerName"

export class InlineSharedWorkerUnavailable extends Error {
  constructor() {
    super(
      "This browser cannot run Inline's single-owner local replica",
    )
    this.name = "InlineSharedWorkerUnavailable"
  }
}

export const supportsInlineSharedWorker = () =>
  typeof SharedWorker !== "undefined" &&
  typeof navigator !== "undefined" &&
  navigator.locks != null

export const createInlineCoreRendererClient = ({
  auth,
  session,
  workerName = activeInlineCoreSharedWorkerName(),
}: {
  auth: AuthStore
  session: AuthSession
  workerName?: string
}) => {
  if (!supportsInlineSharedWorker()) {
    throw new InlineSharedWorkerUnavailable()
  }
  const worker = new SharedWorker(
    new URL("./InlineCore.shared-worker.ts", import.meta.url),
    {
      type: "module",
      name: workerName,
    },
  )
  return new InlineCoreRendererClient({
    port: worker.port,
    owner: worker,
    ownerName: workerName,
    auth,
    session,
  })
}
