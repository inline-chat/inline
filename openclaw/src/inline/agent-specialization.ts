export type InlineAgentSpecialization = {
  name: string
  skillKey?: string
  instructions?: string
}

export function projectInlineAgentSessionKey(
  baseSessionKey: string,
  agentId: string | undefined,
  specialization: InlineAgentSpecialization | null,
): string {
  return agentId && specialization
    ? `${baseSessionKey}:inline-agent:${agentId}`
    : baseSessionKey
}

type CachedSpecialization = {
  value: InlineAgentSpecialization | null
  expiresAt: number
}

export function createInlineAgentSpecializationResolver(params: {
  fetchAgent: (agentId: string) => Promise<InlineAgentSpecialization | null>
  ttlMs?: number
  maxEntries?: number
  now?: () => number
}) {
  const ttlMs = params.ttlMs ?? 60_000
  const maxEntries = params.maxEntries ?? 100
  const now = params.now ?? Date.now
  const cache = new Map<string, CachedSpecialization>()
  const loads = new Map<string, Promise<InlineAgentSpecialization | null>>()

  return {
    async resolve(agentId: string): Promise<InlineAgentSpecialization | null> {
      const cached = cache.get(agentId)
      if (cached && cached.expiresAt > now()) return cached.value

      const existingLoad = loads.get(agentId)
      if (existingLoad) return existingLoad

      const load = params.fetchAgent(agentId)
        .then((value) => {
          cache.delete(agentId)
          cache.set(agentId, { value, expiresAt: now() + ttlMs })
          while (cache.size > maxEntries) {
            const oldest = cache.keys().next().value
            if (oldest === undefined) break
            cache.delete(oldest)
          }
          return value
        })
        .finally(() => {
          if (loads.get(agentId) === load) loads.delete(agentId)
        })
      loads.set(agentId, load)
      return load
    },
  }
}
