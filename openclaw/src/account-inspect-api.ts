import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import { inspectInlineAccount } from "./inline/accounts.js"

export function inspectInlineReadOnlyAccount(cfg: OpenClawConfig, accountId?: string | null) {
  return inspectInlineAccount({ cfg, accountId: accountId ?? null })
}
