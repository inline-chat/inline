import { randomInt } from "node:crypto"
import { and, eq, isNull } from "drizzle-orm"
import { db } from "@in/server/db"
import { inviteCodes, type DbInviteCode } from "@in/server/db/schema"

const inviteAlphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
const inviteCodeLength = 8
const maxCreateAttempts = 20
const devInviteCode = "AAAAAAAA"

export const normalizeInviteCode = (code: string) => code.trim().toUpperCase()

export const isValidInviteCode = (code: string) => /^[A-Z0-9]{8}$/.test(normalizeInviteCode(code))

export const isDevInviteCode = (code: string) => {
  return process.env.NODE_ENV === "development" && normalizeInviteCode(code) === devInviteCode
}

export class InviteCodesModel {
  static generateCode(): string {
    let code = ""
    for (let i = 0; i < inviteCodeLength; i += 1) {
      code += inviteAlphabet[randomInt(inviteAlphabet.length)]
    }
    return code
  }

  static async create(input: {
    count: number
    ownerUserId?: number | null
    createdByUserId?: number | null
    note?: string | null
  }): Promise<DbInviteCode[]> {
    const rows: DbInviteCode[] = []

    for (let i = 0; i < input.count; i += 1) {
      rows.push(await this.createOne(input))
    }

    return rows
  }

  static async redeem(input: { code: string; userId: number; tx?: any }): Promise<DbInviteCode | undefined> {
    const database = input.tx ?? db
    const code = normalizeInviteCode(input.code)

    const [row] = await database
      .update(inviteCodes)
      .set({
        redeemedByUserId: input.userId,
        redeemedAt: new Date(),
      })
      .where(and(eq(inviteCodes.code, code), isNull(inviteCodes.redeemedAt)))
      .returning()

    return row
  }

  static async getByCode(input: { code: string; tx?: any }): Promise<DbInviteCode | undefined> {
    const database = input.tx ?? db
    const code = normalizeInviteCode(input.code)

    return (await database.select().from(inviteCodes).where(eq(inviteCodes.code, code)).limit(1))[0]
  }

  private static async createOne(input: {
    ownerUserId?: number | null
    createdByUserId?: number | null
    note?: string | null
  }): Promise<DbInviteCode> {
    for (let attempt = 0; attempt < maxCreateAttempts; attempt += 1) {
      const [row] = await db
        .insert(inviteCodes)
        .values({
          code: this.generateCode(),
          ownerUserId: input.ownerUserId ?? null,
          createdByUserId: input.createdByUserId ?? null,
          note: input.note?.trim() || null,
        })
        .onConflictDoNothing()
        .returning()

      if (row) {
        return row
      }
    }

    throw new Error("Failed to create unique invite code")
  }
}
