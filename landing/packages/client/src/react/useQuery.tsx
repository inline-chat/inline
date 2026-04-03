import { useEffect, useRef } from "react"
import { useInlineClient } from "./index"
import { Transaction } from "../realtime"

type UseQueryOptions = {
  dependencies?: unknown[]
}

function dependenciesAreEqual(a: unknown[] | null | undefined, b: unknown[] | null | undefined) {
  if (a == null && b != null) return false
  if (a != null && b == null) return false
  if (a == null && b == null) return true

  return (a ?? []).every((value, index) => value === b?.[index])
}

export const useQuery = (query: Transaction, options: UseQueryOptions = {}) => {
  const client = useInlineClient()

  const state = useRef<{
    initial: boolean
    inFlight: boolean
    dependencies: unknown[] | null
  }>({ initial: true, inFlight: false, dependencies: null })

  useEffect(() => {
    // Check dependencies have changed
    if (!state.current.initial && dependenciesAreEqual(state.current.dependencies, options.dependencies)) return
    state.current.initial = false
    state.current.dependencies = options.dependencies ?? []
    state.current.inFlight = true

    console.log("querying", query.method)
    client.realtime
      .query(query)
      .catch((error: unknown) => {
        console.log("failed to query", error)
      })
      .finally(() => {
        console.log("finished querying", query.method)
        state.current.inFlight = false
      })
  }, [client.realtime, query.method, ...(options.dependencies ?? [])])
}
