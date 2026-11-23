import { AsyncLocalStorage } from "node:async_hooks"

/**
 * RPCs issued inside one tool call, by method name. The scope follows the
 * call's async context, so concurrent calls on one legacy session (sharing an
 * InlineApi) each count only their own RPCs. Observability only.
 */
const scope = new AsyncLocalStorage<Record<string, number>>()

export const withRpcAccounting = <T>(counts: Record<string, number>, operation: () => Promise<T>): Promise<T> =>
  scope.run(counts, operation)

export const recordRpc = (method: string): void => {
  const counts = scope.getStore()
  if (counts) counts[method] = (counts[method] ?? 0) + 1
}
