import { eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { dialogs } from "@in/server/db/schema"

export class DialogsModel {
  static async getUserIdsWeHavePrivateDialogsWith({ userId }: { userId: number }): Promise<number[]> {
    const dialogs_ = await db.select({ userId: dialogs.peerUserId }).from(dialogs).where(eq(dialogs.userId, userId))
    return dialogs_.map(({ userId }) => userId).filter((userId): userId is number => userId != null)
  }
}
