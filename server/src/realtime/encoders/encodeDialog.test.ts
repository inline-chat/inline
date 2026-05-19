import { describe, expect, test } from "bun:test"
import type { DbDialog } from "@in/server/db/schema"
import { encodeDialog } from "@in/server/realtime/encoders/encodeDialog"

const baseDialog: DbDialog = {
  id: 1,
  userId: 1,
  chatId: 10,
  peerUserId: null,
  spaceId: null,
  date: new Date("2026-01-01T00:00:00.000Z"),
  readInboxMaxId: null,
  readOutboxMaxId: null,
  pinned: null,
  draft: null,
  archived: false,
  legacySidebarVisible: true,
  chatListHidden: null,
  open: false,
  openedDate: null,
  unreadMark: false,
  notificationSettings: null,
}

const encode = (overrides: Partial<DbDialog> = {}) =>
  encodeDialog({ ...baseDialog, ...overrides }, { unreadCount: 0 })

describe("encodeDialog", () => {
  test("emits legacy sidebar visibility as the inverse of chatListHidden", () => {
    const visible = encode({ chatListHidden: null })
    expect(visible.sidebarVisible).toBe(true)
    expect(visible.chatListHidden).toBeUndefined()

    const hidden = encode({ chatListHidden: true })
    expect(hidden.sidebarVisible).toBe(false)
    expect(hidden.chatListHidden).toBe(true)
  })

  test("treats null open state as closed", () => {
    const thread = encode({ peerUserId: null, open: null })
    expect(thread.open).toBe(false)

    const dm = encode({ peerUserId: 2, open: null })
    expect(dm.open).toBe(false)

    const openDm = encode({ peerUserId: 2, open: true })
    expect(openDm.open).toBe(true)
  })
})
