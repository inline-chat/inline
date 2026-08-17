import { describe, expect, test } from "bun:test"
import type { DbFile, DbUserWithPhoto } from "@in/server/db/schema"
import {
  encodeFullUserInfo,
  encodePhotoInfo,
} from "./api-schema"

const userFixture = (): DbUserWithPhoto => ({
  id: 1000,
  email: "person@example.com",
  phoneNumber: null,
  emailVerified: true,
  phoneVerified: null,
  firstName: "Inline",
  lastName: "User",
  bio: null,
  username: "inline-user",
  deleted: false,
  online: false,
  lastOnline: null,
  date: new Date("2026-08-17T10:49:00Z"),
  photoFileId: null,
  pendingSetup: false,
  timeZone: "UTC",
  shareTimeZone: true,
  appearInGlobalSearch: true,
  nextThreadNumber: 1,
  bot: false,
  botCreatorId: null,
  updateSeq: 0,
  lastUpdateDate: null,
  photo: null,
})

describe("public user encoding", () => {
  test("projects only declared public user fields", () => {
    const encoded = JSON.parse(
      JSON.stringify(encodeFullUserInfo(userFixture())),
    ) as Record<string, unknown>

    expect(encoded).toEqual({
      id: 1000,
      firstName: "Inline",
      lastName: "User",
      bio: null,
      username: "inline-user",
      email: "person@example.com",
      phoneNumber: null,
      pendingSetup: false,
      online: false,
      lastOnline: null,
      timeZone: "UTC",
      date: 1_786_963_740,
    })
    expect(encoded).not.toHaveProperty("emailVerified")
    expect(encoded).not.toHaveProperty("phoneVerified")
    expect(encoded).not.toHaveProperty("deleted")
    expect(encoded).not.toHaveProperty("photoFileId")
  })

  test("normalizes nullable historical photo metadata", () => {
    const encoded = encodePhotoInfo({
      fileUniqueId: "provider-photo-test",
      fileType: "photo",
      width: null,
      height: null,
      fileSize: null,
      mimeType: null,
    } as DbFile)

    expect(encoded).toMatchObject({
      fileUniqueId: "provider-photo-test",
      width: 0,
      height: 0,
      fileSize: 0,
      mimeType: "application/octet-stream",
    })
  })
})
