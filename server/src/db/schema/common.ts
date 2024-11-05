import { timestamp } from "drizzle-orm/pg-core"
import { customType } from "drizzle-orm/pg-core"

export const bytea = customType<{
  data: Buffer
  notNull: false
  default: false
}>({
  dataType() {
    return "bytea"
  },
})

export const creationDate = timestamp("date", {
  mode: "date",
  precision: 3,
})
  .defaultNow()
  .notNull()

export const date = timestamp("date", {
  mode: "date",
  precision: 3,
})
