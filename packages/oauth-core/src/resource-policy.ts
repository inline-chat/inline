export type OAuthResourcePolicy<Scope extends string = string> = {
  resource: string
  supportedScopes: readonly Scope[]
  defaultScopes: readonly Scope[]
  resourceScopes: readonly Scope[]
}

export function normalizeScopesForPolicy<Scope extends string>(
  scope: string,
  policy: OAuthResourcePolicy<Scope>,
): string {
  const supported = new Set<string>(policy.supportedScopes)
  const values: string[] = []
  const seen = new Set<string>()
  for (const part of scope.split(/\s+/)) {
    const value = part.trim()
    if (!value || seen.has(value) || !supported.has(value)) continue
    seen.add(value)
    values.push(value)
  }
  return (values.length > 0 ? values : [...policy.defaultScopes]).join(" ")
}

export function policyAcceptsResource(policy: OAuthResourcePolicy, resource: string): boolean {
  return resource === policy.resource
}
