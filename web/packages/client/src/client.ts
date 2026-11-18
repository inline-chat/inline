import type { AuthStore } from "./auth"
import type { Db } from "./database"
import type { RealtimeService } from "./realtime"

export type InlineClientContextValue = {
  realtime: RealtimeService
  db: Db
  auth: AuthStore
}
