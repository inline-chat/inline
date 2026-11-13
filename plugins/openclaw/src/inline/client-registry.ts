import { InlineSdkClient } from "@inline-chat/realtime-sdk"

/**
 * One realtime connection per account. The monitor shares its live client so
 * tools, outbound sends and commands reuse it instead of opening a connection
 * per call. Callers outside a running monitor (CLI, setup, probe) still get a
 * short-lived client that is closed after use.
 */
type SharedInlineClient = {
  client: InlineSdkClient
  baseUrl: string
  token: string
  active: boolean
}

// The build bundles each plugin entry separately (no code splitting), so the
// monitor (channel entry) and the tools (runtime-register entry) each carry their
// own copy of this module. A process-wide key gives them one map.
const SHARED_CLIENTS_KEY = Symbol.for("inline-openclaw.sharedClients.v1")
const sharedClients: Map<string, SharedInlineClient> = ((globalThis as Record<symbol, unknown>)[
  SHARED_CLIENTS_KEY
] ??= new Map<string, SharedInlineClient>()) as Map<string, SharedInlineClient>

export function shareInlineAccountClient(params: {
  accountId: string
  baseUrl: string
  token: string
  client: InlineSdkClient
}): () => void {
  const entry: SharedInlineClient = {
    client: params.client,
    baseUrl: params.baseUrl,
    token: params.token,
    active: true,
  }
  sharedClients.set(params.accountId, entry)
  return () => {
    entry.active = false
    if (sharedClients.get(params.accountId) === entry) {
      sharedClients.delete(params.accountId)
    }
  }
}

export function getSharedInlineAccountClient(params: {
  accountId: string
  baseUrl: string
  token: string
}): InlineSdkClient | undefined {
  const entry = sharedClients.get(params.accountId)
  if (!entry?.active) return undefined
  // A token or server change means the monitor is about to restart; don't
  // send with the old identity.
  if (entry.baseUrl !== params.baseUrl || entry.token !== params.token) return undefined
  return entry.client
}

export type InlineClientLease = {
  client: InlineSdkClient
  /** Closes the client only when this lease opened it; the shared one stays up. */
  release: () => Promise<void>
}

export async function acquireInlineAccountClient(params: {
  accountId: string
  baseUrl: string
  token: string
  signal?: AbortSignal | undefined
}): Promise<InlineClientLease> {
  params.signal?.throwIfAborted()
  const shared = getSharedInlineAccountClient(params)
  if (shared) return { client: shared, release: async () => {} }

  const client = new InlineSdkClient({ baseUrl: params.baseUrl, token: params.token })
  try {
    await client.connect(params.signal)
    params.signal?.throwIfAborted()
  } catch (error) {
    await client.close().catch(() => {})
    throw error
  }
  return { client, release: async () => { await client.close().catch(() => {}) } }
}

export async function withInlineAccountClient<T>(
  params: { accountId: string; baseUrl: string; token: string; signal?: AbortSignal | undefined },
  fn: (client: InlineSdkClient) => Promise<T>,
): Promise<T> {
  const lease = await acquireInlineAccountClient(params)
  try {
    params.signal?.throwIfAborted()
    return await fn(lease.client)
  } finally {
    await lease.release()
  }
}

export function resetSharedInlineClientsForTest(): void {
  sharedClients.clear()
}
