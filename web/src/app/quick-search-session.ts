/**
 * Quick Search for one session with the core's sources: local messages
 * (`searchMessages`) and server people (`searchUsers`). Server message
 * search covers one chat only, so it is find in chat's second source, not
 * Quick Search's. Part of the Quick Search chunk (`quick-search-chunk.ts`);
 * no view code, so tests use it directly.
 */

import type { AccountSession } from "@inline/view/features"
import { createCoreMessageSource, createCoreRemoteSource } from "../features/quick-search/core-sources"
import { wireQuickSearch, type QuickSearchWiring, type QuickSearchWiringOptions } from "../features/quick-search/wiring"

export const wireSessionQuickSearch = (
  session: AccountSession,
  options: Omit<QuickSearchWiringOptions, "messages" | "remote">,
): QuickSearchWiring =>
  wireQuickSearch(session, {
    ...options,
    messages: createCoreMessageSource({ client: session.client, coreResource: session.coreResource }),
    remote: createCoreRemoteSource({ client: session.client }),
  })
