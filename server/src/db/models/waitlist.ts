import { db } from "@in/server/db"
import { NewWaitlistSubscriber, waitlist } from "@in/server/db/schema"

export async function insertIntoWaitlist(subscriber: NewWaitlistSubscriber) {
  return db.insert(waitlist).values(subscriber).returning()
}
