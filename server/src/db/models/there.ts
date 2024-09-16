import { db } from "@in/server/db"
import { NewThereUser, thereUsers } from "../schema/there"

export async function insertThereUser(subscriber: NewThereUser) {
  return db.insert(thereUsers).values(subscriber).returning()
}
