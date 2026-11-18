/**
 * The service worker script's entry. Built by `web/tooling/service-worker-plugin.ts`
 * into the unhashed `/sw.js` as a classic script (module service workers are
 * not available at our Firefox 128 floor; a classic script works everywhere), with `__INLINE_SW_CONFIG__` replaced by the build's
 * precache manifest.
 */

import type { ServiceWorkerConfig } from "./protocol"
import { installServiceWorker } from "./service-worker"
import type { ServiceWorkerScopeLike } from "./types"

declare const __INLINE_SW_CONFIG__: ServiceWorkerConfig

installServiceWorker(self as unknown as ServiceWorkerScopeLike, __INLINE_SW_CONFIG__)
