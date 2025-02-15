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
  toDriver(value) {
    return value as Buffer
  },
  fromDriver(value) {
    if (typeof value === "string") {
      return Buffer.from(value.replaceAll("\\x", ""), "hex")
    }
    if (value instanceof Buffer) {
      return value
    }
    throw new Error("Invalid value type return in bytea type")
  },
})

export const creationDate = timestamp("date", {
  mode: "date",
  precision: 3,
})
  .defaultNow()
  .notNull()

export const date = timestamp({
  mode: "date",
  precision: 3,
})
