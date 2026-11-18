import { DialogNotificationSettings_Mode } from "@inline-chat/protocol/core"
import { inlineId, spaceId, userId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { DbObjectKind, spaceMemberKey } from "../../database/models"
import { syncBucketId } from "../../realtime/sync/sync-types"
import { deferredUpdateRecord } from "../../realtime/updates/apply-updates"
import { bucketKeyFor, type ReplicaSnapshot } from "../core-harness"
import { ServerModel } from "../server-model"
import { compareReplica } from "./compare"
import { defaultConfig, defaultWeights, formatReport, runSchedule } from "./schedule"

/**
 * The membership, notification-mode and raw-retention properties can see a
 * divergence, and schedules weighted toward those events converge.
 */

const emptyReplica = (model: ServerModel): ReplicaSnapshot => ({
  messages: [],
  chats: [],
  dialogs: [],
  pendingTransactions: [],
  buckets: model.bucketIds().map((bucketId) => ({
    kind: DbObjectKind.SyncBucketState,
    id: syncBucketId(bucketKeyFor(bucketId)),
    seq: model.bucketSeq(bucketId),
    date: 0,
  })),
  deferredUpdates: [],
  spaceMembers: [],
  residentMessages: [],
})

describe("model-sync coverage properties", () => {
  it("reports missing members, a wrong notification mode and a lost raw record", () => {
    const model = new ServerModel({ now: () => 1_000 })
    model.addSpace(100n)
    model.addChat({ id: 10n })
    model.addSpaceMember(100n, 50n)
    model.addSpaceMember(100n, 51n)
    model.removeSpaceMember(100n, 50n)
    model.setNotificationMode(10n, DialogNotificationSettings_Mode.NONE)
    model.addRawRecord()

    const replica = emptyReplica(model)
    replica.dialogs = [
      { kind: DbObjectKind.Dialog, id: "10" as never, chatId: "10" as never, readMaxId: undefined },
    ]
    const properties = compareReplica(model, replica, { unverifiableReactions: new Set() }).map(
      (divergence) => divergence.property,
    )
    expect(properties).toEqual(
      expect.arrayContaining(["members.set", "dialog.notificationMode", "deferred.retained"]),
    )

    replica.spaceMembers = [
      {
        kind: DbObjectKind.SpaceMember,
        id: spaceMemberKey(spaceId(100), userId(51)),
        memberId: inlineId(2),
        spaceId: spaceId(100),
        userId: userId(51),
        date: 1_000,
        canAccessPublicChats: true,
      },
    ]
    replica.dialogs = [{ ...replica.dialogs[0]!, notificationMode: "none" }]
    replica.deferredUpdates = model
      .journalKinds("user")
      .filter((entry) => entry.kind === "agentSettings")
      .map((entry) =>
        deferredUpdateRecord({
          seq: entry.seq,
          date: 1_000n,
          update: { oneofKind: "agentSettings", agentSettings: {} },
        }),
      )
    const fixed = compareReplica(model, replica, { unverifiableReactions: new Set() }).map(
      (divergence) => divergence.property,
    )
    expect(fixed).not.toContain("members.set")
    expect(fixed).not.toContain("dialog.notificationMode")
    expect(fixed).not.toContain("deferred.retained")
  })

  it.each([1, 2, 3, 4, 5])(
    "seed %i weighted toward membership and dialog-state events converges strictly",
    async (seed) => {
      const result = await runSchedule(seed, {
        ...defaultConfig,
        weights: { ...defaultWeights, spaceMember: 8, notificationMode: 6, rawRecord: 3 },
      })
      if (result.divergences.length > 0) throw new Error(formatReport(result))
      expect(result.trace.some((line) => line.includes("spaceMember"))).toBe(true)
      expect(result.trace.some((line) => line.includes("notificationMode"))).toBe(true)
    },
  )
})
