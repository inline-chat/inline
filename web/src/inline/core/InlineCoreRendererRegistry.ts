import type { AuthStore } from "@inline/client/core"
import type { UserID } from "@inline/ids"
import { InlineCoreRendererClient } from "./InlineCoreRendererClient"
import { createInlineCoreRendererClient } from "./createInlineCoreRendererClient"
import { replacementInlineCoreSharedWorkerName } from "./InlineCoreSharedWorkerName"

type RegistryEntry = {
  accountId: UserID
  client: InlineCoreRendererClient
  token: string
  references: number
  detachTimer: ReturnType<typeof setTimeout> | null
}

export class InlineCoreRendererRegistry {
  private readonly entries = new Map<UserID, RegistryEntry>()

  constructor(
    private readonly createClient = createInlineCoreRendererClient,
  ) {}

  get(accountId: UserID, auth: AuthStore) {
    const token = auth.getToken()
    if (!token) {
      throw new Error(
        "Cannot create Inline core renderer without a session",
      )
    }

    const existing = this.entries.get(accountId)
    if (existing?.token === token) return existing.client
    if (existing && existing.references > 0) {
      throw new Error(
        "Cannot replace an active Inline core renderer session",
      )
    }
    if (existing) {
      existing.client.detach()
      this.entries.delete(accountId)
    }

    const client = this.createClient({
      auth,
      session: { token, userId: accountId },
    })
    this.entries.set(accountId, {
      accountId,
      client,
      token,
      references: 0,
      detachTimer: null,
    })
    return client
  }

  retain(client: InlineCoreRendererClient) {
    const entry = this.entries.get(client.accountId)
    if (!entry || entry.client !== client) {
      throw new Error(
        "Inline core renderer client is not registered",
      )
    }
    if (entry.detachTimer) {
      clearTimeout(entry.detachTimer)
      entry.detachTimer = null
    }
    entry.references += 1
    void client.start().catch(() => undefined)

    let released = false
    return () => {
      if (released) return
      released = true
      entry.references = Math.max(0, entry.references - 1)
      this.scheduleDetach(entry)
    }
  }

  replaceUnresponsiveBootOwner(
    client: InlineCoreRendererClient,
    auth: AuthStore,
  ) {
    const entry = this.entries.get(client.accountId)
    const token = auth.getToken()
    if (
      !entry ||
      entry.client !== client ||
      !token ||
      entry.token !== token ||
      !client.canReplaceUnresponsiveBootOwner()
    ) {
      return undefined
    }

    client.detach()
    const replacement = this.createClient({
      auth,
      session: { token, userId: client.accountId },
      workerName: replacementInlineCoreSharedWorkerName(),
    })
    this.entries.set(client.accountId, {
      accountId: client.accountId,
      client: replacement,
      token,
      references: 0,
      detachTimer: null,
    })
    return replacement
  }

  private scheduleDetach(entry: RegistryEntry) {
    if (entry.references > 0 || entry.detachTimer) return
    entry.detachTimer = setTimeout(() => {
      entry.detachTimer = null
      if (entry.references > 0) return
      if (this.entries.get(entry.accountId) === entry) {
        this.entries.delete(entry.accountId)
      }
      entry.client.detach()
    }, 0)
  }
}
