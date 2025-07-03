import { ServerUpdate } from "@in/protocol/server"
import { db } from "@in/server/db"
import { chats, spaces, users } from "@in/server/db/schema"
import { updates, type DbUpdate } from "@in/server/db/schema/updates"
import { decryptBinary, encryptBinary } from "@in/server/modules/encryption/encryption"
import { eq } from "drizzle-orm"

export const UpdatesModel = {
  create: createUpdate,
  build: buildServerUpdate,
  decrypt: decryptUpdate,
}

export type DecryptedUpdate = Omit<DbUpdate, "update" | "updateIv" | "updateTag"> & {
  update: ServerUpdate
}

function decryptUpdate(dbUpdate: DbUpdate): DecryptedUpdate {
  const { update: encrypted, updateIv, updateTag, ...rest } = dbUpdate
  const binary = decryptBinary({ encrypted, iv: updateIv, authTag: updateTag })
  const update = ServerUpdate.fromBinary(binary)
  return { ...rest, update }
}

export type UpdateBoxInput =
  | {
      type: "c"
      chatId: number
    }
  | {
      type: "u"
      userId: number
    }
  | {
      type: "s"
      spaceId: number
    }

type CreateUpdateInput = {
  box: UpdateBoxInput
  update: ServerUpdate
}

function buildServerUpdate(update: ServerUpdate) {
  let binary = ServerUpdate.toBinary(update)
  let { encrypted, iv, authTag } = encryptBinary(binary)

  return {
    encrypted,
    iv,
    authTag,
  }
}

async function createUpdate(input: CreateUpdateInput) {
  const { box, update } = input

  let binary = ServerUpdate.toBinary(update)
  let { encrypted, iv, authTag } = encryptBinary(binary)

  // get sequence number in a transaction
  await db.transaction(async (tx) => {
    let pts: number | null = null

    switch (box.type) {
      case "c":
        let chat = await tx
          .select({ pts: chats.pts })
          .from(chats)
          .where(eq(chats.id, box.chatId))
          .for("update")
          .limit(1)
        pts = chat[0]?.pts ?? null
        break
      case "u":
        let user = await tx
          .select({ pts: users.pts })
          .from(users)
          .where(eq(users.id, box.userId))
          .for("update")
          .limit(1)
        pts = user[0]?.pts ?? null
        break
      case "s":
        let space = await tx
          .select({ pts: spaces.pts })
          .from(spaces)
          .where(eq(spaces.id, box.spaceId))
          .for("update")
          .limit(1)
        pts = space[0]?.pts ?? null
        break
    }

    if (pts === null) {
      throw new Error("Sequence number not found")
    }

    // Increment sequence number
    pts++

    // Insert new update
    await tx.insert(updates).values({
      pts: pts,
      box: box.type,
      date: new Date(),
      update: encrypted,
      updateIv: iv,
      updateTag: authTag,
    })

    // Update sequence number
    switch (box.type) {
      case "c":
        await tx.update(chats).set({ pts }).where(eq(chats.id, box.chatId))
        break
      case "u":
        await tx.update(users).set({ pts }).where(eq(users.id, box.userId))
        break
      case "s":
        await tx.update(spaces).set({ pts }).where(eq(spaces.id, box.spaceId))
        break
    }
  })
}
