import type { db } from "@in/server/db"

export type Transaction = Parameters<Parameters<(typeof db)["transaction"]>[0]>[0]
