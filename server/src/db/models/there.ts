import { db } from "@in/server/db"
import { thereUsers, type NewThereUser } from "../schema/there"

export async function insertThereUser(subscriber: NewThereUser) {
  return db.insert(thereUsers).values(subscriber).returning()
}
