import { db } from "@in/server/db"
import { files, type DbFile } from "@in/server/db/schema"
import { eq } from "drizzle-orm"

export const getFileByUniqueId = async (fileUniqueId: string): Promise<DbFile | undefined> => {
  const [file] = await db.select().from(files).where(eq(files.fileUniqueId, fileUniqueId)).limit(1)
  return file
}
