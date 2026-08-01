import { db } from "@in/server/db"
import { type NewWaitlistSubscriber, waitlist } from "@in/server/db/schema"

export async function insertIntoWaitlist(subscriber: NewWaitlistSubscriber) {
  const rows = await db
    .insert(waitlist)
    .values(subscriber)
    .onConflictDoNothing({ target: waitlist.email })
    .returning({ id: waitlist.id })

  return rows.length > 0
}
