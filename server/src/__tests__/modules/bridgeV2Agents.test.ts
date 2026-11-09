import { afterAll, beforeEach, describe, expect, test } from "bun:test"
import {
  AgentGrantOperation,
  AgentGrantRequirement,
  AgentOutputMode,
  AgentParticipationMode,
  AgentRunState,
  AgentSessionControl,
  AgentSessionProvider,
  AgentAttentionKind,
  BlockFormText_Kind,
  BotCapability_Kind,
  RpcError_Code,
  type BlockText,
  type InputPeer,
} from "@inline-chat/protocol/core"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { UpdatesModel } from "@in/server/db/models/updates"
import { agentGrants, agentRuntimes, chats, updates, users } from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { answerMessageAction } from "@in/server/functions/messages.answerMessageAction"
import { invokeMessageAction } from "@in/server/functions/messages.invokeMessageAction"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { controlAgentSession } from "@in/server/modules/agentSessions/control"
import { moveAgentSession } from "@in/server/modules/agentSessions/move"
import { connectAgentSession, getAgentSession } from "@in/server/modules/agentSessions/service"
import { getAgentSessionStates, updateAgentSessionState } from "@in/server/modules/agentSessions/state"
import {
  deleteAgentGrant,
  importAgentGrants,
  listAgentGrants,
  setAgentGrant,
} from "@in/server/modules/agents/grants"
import { setAgentParticipation } from "@in/server/modules/agents/participation"
import {
  reportAgentRuntime,
  stopAgentRuntimeSweeper,
  sweepLapsedAgentRuntimes,
} from "@in/server/modules/agents/runtime"
import { getAgentSettings, updateAgentSettings } from "@in/server/modules/agents/settings"
import { normalizeBotCapabilities, toProtocolBotCapability } from "@in/server/functions/bot.capabilitiesShared"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { and, desc, eq } from "drizzle-orm"

const rejects = async (promise: Promise<unknown>, code: RpcError_Code) => {
  const error = await promise.then(() => undefined, (caught: unknown) => caught)
  expect(RealtimeRpcError.is(error, code)).toBe(true)
}

describe("bridge v2 agent server", () => {
  setupTestLifecycle()
  afterAll(() => stopAgentRuntimeSweeper())

  let ownerId = 0
  let botId = 0
  let teammateId = 0
  let strangerId = 0
  let chatId = 0
  let peer: InputPeer

  beforeEach(async () => {
    const [owner, bot, teammate, stranger] = await Promise.all(["owner", "bot", "teammate", "stranger"].map((name) =>
      testUtils.createUser(`bv2-${name}-${crypto.randomUUID()}@example.com`)))
    ownerId = owner!.id
    botId = bot!.id
    teammateId = teammate!.id
    strangerId = stranger!.id
    await db.update(users).set({ bot: true, botCreatorId: ownerId }).where(eq(users.id, botId))
    const chat = await testUtils.createChat(null, "Agent work", "thread", false, ownerId)
    if (!chat) throw new Error("chat not created")
    chatId = chat.id
    peer = { type: { oneofKind: "chat", chat: { chatId: BigInt(chatId) } } }
    await Promise.all([ownerId, botId, teammateId].map((id) => testUtils.addParticipant(chatId, id)))
  })

  const grant = (userId: number, operations: AgentGrantOperation[], actor = ownerId) =>
    setAgentGrant({ botUserId: BigInt(botId), userId: BigInt(userId), operations }, actor)

  test("grants are opt-in, owner-edited, and revisioned through deletes", async () => {
    // The bot may grant like /allowlist, but never approval delegation.
    await rejects(grant(teammateId, [AgentGrantOperation.APPROVE], botId), RpcError_Code.USER_ID_INVALID)
    await rejects(grant(teammateId, [AgentGrantOperation.STEER], strangerId), RpcError_Code.USER_ID_INVALID)

    const first = await grant(teammateId, [AgentGrantOperation.INVOKE, AgentGrantOperation.STEER], botId)
    await grant(strangerId, [AgentGrantOperation.CONFIGURE])
    expect(first.grant?.operations).toEqual([AgentGrantOperation.INVOKE, AgentGrantOperation.STEER])

    const asOwner = await listAgentGrants({ botUserId: BigInt(botId) }, ownerId)
    expect(asOwner.grants.map((row) => Number(row.userId)).sort()).toEqual([teammateId, strangerId].sort())
    const asTeammate = await listAgentGrants({ botUserId: BigInt(botId) }, teammateId)
    expect(asTeammate.grants.map((row) => Number(row.userId))).toEqual([teammateId])
    expect(asTeammate.ownerUserId).toBe(BigInt(ownerId))

    const deleted = await deleteAgentGrant({ botUserId: BigInt(botId), userId: BigInt(strangerId) }, ownerId)
    expect(deleted.revision).toBeGreaterThan(asOwner.revision)
    expect((await listAgentGrants({ botUserId: 0n }, botId)).grants).toHaveLength(1)
  })

  test("the allowlist import runs once, into an empty grant table", async () => {
    const imported = await importAgentGrants({ userIds: [BigInt(teammateId), BigInt(ownerId), BigInt(botId)] }, botId)
    expect(imported.grants.map((row) => [Number(row.userId), row.operations])).toEqual([
      [teammateId, [AgentGrantOperation.INVOKE, AgentGrantOperation.STEER]],
    ])
    await deleteAgentGrant({ botUserId: BigInt(botId), userId: BigInt(teammateId) }, ownerId)
    // The owner's removal wins over a later import.
    const again = await importAgentGrants({ userIds: [BigInt(teammateId)] }, botId)
    expect(again.grants).toHaveLength(0)
  })

  test("required grants and secret form values are enforced before the bot", async () => {
    let text = ""
    const range = (value: string): BlockText => {
      const offset = text.length
      text += value + "\n"
      return { offset: BigInt(offset), length: BigInt(value.length) }
    }
    const blocks = {
      blocks: [{
        kind: {
          oneofKind: "form" as const,
          form: {
            formId: "question",
            title: range("Deploy key?"),
            requiredGrant: AgentGrantRequirement.ACCESS,
            closed: false,
            fields: [{
              fieldId: "key",
              label: range("Key"),
              required: true,
              kind: { oneofKind: "text" as const, text: { kind: BlockFormText_Kind.SECRET } },
            }],
          },
        },
      }],
    }
    const sent = await sendMessage({
      peerId: peer,
      message: text,
      botBlockContent: blocks,
      actions: {
        rows: [{
          actions: [{
            actionId: "approve",
            text: "Approve",
            action: { oneofKind: "callback", callback: { data: new TextEncoder().encode("yes") } },
            style: 1,
            requiredGrant: AgentGrantRequirement.APPROVE,
          }],
        }],
      },
    }, testUtils.functionContext({ userId: botId }))
    const messageUpdate = sent.updates.find((update) => update.update.oneofKind === "newMessage")
    const messageId = messageUpdate?.update.oneofKind === "newMessage" ? messageUpdate.update.newMessage.message!.id : 0n
    expect(messageId).toBeGreaterThan(0n)

    const invoke = (userId: number, actionId: string, secret?: string) => invokeMessageAction({
      peerId: peer,
      messageId,
      actionId,
      form: secret === undefined
        ? undefined
        : { values: [{ fieldId: "key", value: { oneofKind: "text", text: secret }, redacted: false }] },
    }, testUtils.functionContext({ userId }))

    await rejects(invoke(teammateId, "approve"), RpcError_Code.AGENT_GRANT_REQUIRED)
    await rejects(invoke(teammateId, "question", "k1"), RpcError_Code.AGENT_GRANT_REQUIRED)
    await grant(teammateId, [AgentGrantOperation.STEER])
    // Any grant answers questions; approvals need the approve grant.
    await rejects(invoke(teammateId, "approve"), RpcError_Code.AGENT_GRANT_REQUIRED)
    const answered = await invoke(teammateId, "question", "super-secret-key")
    await grant(teammateId, [AgentGrantOperation.APPROVE])
    expect((await invoke(teammateId, "approve")).interactionId).toBeGreaterThan(0n)
    expect((await invoke(ownerId, "approve")).interactionId).toBeGreaterThan(0n)

    const [stored] = await db.select().from(updates).where(and(
      eq(updates.bucket, UpdateBucket.User),
      eq(updates.entityId, botId),
      eq(updates.seq, Number(answered.interactionId)),
    ))
    const payload = UpdatesModel.decrypt(stored!).payload.update
    expect(payload.oneofKind).toBe("userMessageActionInvoked")
    if (payload.oneofKind !== "userMessageActionInvoked") return
    expect(payload.userMessageActionInvoked.form?.values).toEqual([{ fieldId: "key", value: { oneofKind: undefined }, redacted: true }])
    expect(JSON.stringify(payload, (_, value) => typeof value === "bigint" ? value.toString() : value)).not.toContain("super-secret-key")
  })

  test("run state is revisioned, filtered for attention, and listed for badges", async () => {
    const connected = await connectAgentSession({
      peerId: peer,
      botUserId: BigInt(botId),
      provider: AgentSessionProvider.CODEX,
      instanceRef: "codex-installation",
      sessionRef: "codex-session",
      relation: 0,
    }, ownerId)
    const agentSessionId = connected.agentSession!.id
    const report = (revision: bigint, runState: AgentRunState) => updateAgentSessionState({
      agentSessionId,
      state: {
        runState,
        waitingReason: 1,
        revision,
        queuedCount: 0,
        updatedAt: 0n,
        attention: { kind: AgentAttentionKind.APPROVAL, userIds: [BigInt(ownerId), BigInt(strangerId)], text: "Approve: rm" },
      },
    }, botId)

    const applied = await report(10n, AgentRunState.WAITING)
    expect(applied.applied).toBe(true)
    // The stranger cannot see the chat, so the attention never reaches them.
    expect(applied.agentSession?.state?.attention?.userIds).toEqual([BigInt(ownerId)])
    expect((await report(9n, AgentRunState.IDLE)).applied).toBe(false)
    await rejects(updateAgentSessionState({ agentSessionId, state: applied.agentSession!.state! }, teammateId), RpcError_Code.BAD_REQUEST)

    const badges = await getAgentSessionStates({}, teammateId)
    expect(badges.sessions.map((session) => session.id)).toEqual([agentSessionId])
    expect((await getAgentSessionStates({}, strangerId)).sessions).toHaveLength(0)

    // Work bar controls need the steer grant.
    await rejects(controlAgentSession({ agentSessionId, op: AgentSessionControl.PAUSE }, teammateId), RpcError_Code.AGENT_GRANT_REQUIRED)
    await grant(teammateId, [AgentGrantOperation.STEER])
    const { interactionId } = await controlAgentSession({ agentSessionId, op: AgentSessionControl.PAUSE }, teammateId)
    expect(interactionId).toBeGreaterThan(0n)

    // The bot answers the control like a button, and the toast reaches the
    // person who pressed it; nobody else can answer it.
    const toast = { kind: { oneofKind: "toast" as const, toast: { text: "Paused." } } }
    await rejects(
      answerMessageAction({ interactionId, ui: toast }, { currentUserId: teammateId, currentSessionId: 0 }),
      RpcError_Code.BAD_REQUEST,
    )
    await answerMessageAction({ interactionId, ui: toast }, { currentUserId: botId, currentSessionId: 0 })
    const [answered] = await db.select().from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, teammateId)))
      .orderBy(desc(updates.seq)).limit(1)
    const answer = UpdatesModel.decrypt(answered!).payload.update
    expect(answer.oneofKind).toBe("userMessageActionAnswered")
    if (answer.oneofKind === "userMessageActionAnswered") {
      expect(answer.userMessageActionAnswered.interactionId).toBe(interactionId)
      expect(answer.userMessageActionAnswered.ui).toEqual(toast)
    }
  })

  test("setting only the output mode never joins the agent to ambient conversation", async () => {
    const created = await setAgentParticipation({ peerId: peer, botUserId: BigInt(botId), mode: 0, outputMode: AgentOutputMode.FRIENDLY }, ownerId)
    expect(created.participation?.mode).toBe(AgentParticipationMode.MENTIONS_ONLY)
    // An existing participation keeps its mode.
    await setAgentParticipation({ peerId: peer, botUserId: BigInt(botId), mode: AgentParticipationMode.ACTIVE }, ownerId)
    const kept = await setAgentParticipation({ peerId: peer, botUserId: BigInt(botId), mode: 0, outputMode: AgentOutputMode.DETAILED }, ownerId)
    expect(kept.participation?.mode).toBe(AgentParticipationMode.ACTIVE)
  })

  test("participation and output mode follow grants", async () => {
    await rejects(setAgentParticipation({ peerId: peer, botUserId: BigInt(botId), mode: AgentParticipationMode.MUTED }, teammateId), RpcError_Code.AGENT_GRANT_REQUIRED)
    const joined = await setAgentParticipation({ peerId: peer, botUserId: BigInt(botId), mode: AgentParticipationMode.ACTIVE, joinedBy: BigInt(teammateId) }, botId)
    expect(joined.participation?.joinedBy).toBe(BigInt(teammateId))

    // Participation settings need CONFIGURE (spec §7), not just any grant.
    await grant(teammateId, [AgentGrantOperation.STEER])
    await rejects(setAgentParticipation({ peerId: peer, botUserId: BigInt(botId), mode: AgentParticipationMode.MUTED }, teammateId), RpcError_Code.AGENT_GRANT_REQUIRED)
    await grant(teammateId, [AgentGrantOperation.STEER, AgentGrantOperation.CONFIGURE])
    const muted = await setAgentParticipation({ peerId: peer, botUserId: BigInt(botId), mode: AgentParticipationMode.MUTED }, teammateId)
    expect(muted.participation?.mode).toBe(AgentParticipationMode.MUTED)
    const friendly = await setAgentParticipation({ peerId: peer, botUserId: BigInt(botId), mode: 0, outputMode: AgentOutputMode.FRIENDLY }, ownerId)
    expect([friendly.participation?.mode, friendly.participation?.outputMode]).toEqual([AgentParticipationMode.MUTED, AgentOutputMode.FRIENDLY])
    const cleared = await setAgentParticipation({ peerId: peer, botUserId: BigInt(botId), mode: 0, outputMode: AgentOutputMode.UNSPECIFIED }, ownerId)
    expect(cleared.participation?.outputMode).toBeUndefined()

    // A runtime's mirror of the default follows the settings.
    await reportAgentRuntime({ provider: AgentSessionProvider.CODEX, status: 1, executablePath: "/opt/codex" }, botId)
    const settings = await updateAgentSettings({ botUserId: BigInt(botId), defaultOutputMode: AgentOutputMode.FRIENDLY }, ownerId)
    expect([settings.runtime?.defaultOutputMode, settings.runtime?.executablePath]).toEqual([AgentOutputMode.FRIENDLY, "/opt/codex"])
    const [row] = await db.select().from(agentGrants).where(eq(agentGrants.subjectUserId, teammateId)).orderBy(desc(agentGrants.id))
    expect(row?.revokedAt).toBeNull()
  })

  const latestUserUpdate = async (userId: number) => {
    const [row] = await db.select().from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, userId)))
      .orderBy(desc(updates.seq)).limit(1)
    return row ? UpdatesModel.decrypt(row).payload.update : undefined
  }

  test("settings exist for any owned bot, without a runtime", async () => {
    const untouched = await getAgentSettings({ botUserId: 0n }, botId)
    expect([untouched.settings?.defaultOutputMode, untouched.settings?.revision, untouched.settings?.date])
      .toEqual([AgentOutputMode.UNSPECIFIED, 0n, undefined])

    const first = await updateAgentSettings({ botUserId: BigInt(botId), defaultOutputMode: AgentOutputMode.FRIENDLY }, ownerId)
    expect(first.runtime).toBeUndefined()
    expect([first.settings?.defaultOutputMode, first.settings?.revision]).toEqual([AgentOutputMode.FRIENDLY, 1n])
    const second = await updateAgentSettings({ botUserId: BigInt(botId), defaultOutputMode: AgentOutputMode.DETAILED }, ownerId)
    expect(second.settings?.revision).toBe(2n)
    // No fields: nothing changes.
    const unchanged = await updateAgentSettings({ botUserId: BigInt(botId) }, ownerId)
    expect([unchanged.settings?.defaultOutputMode, unchanged.settings?.revision]).toEqual([AgentOutputMode.DETAILED, 2n])

    // The harness reads its own settings, and gets the change pushed.
    expect((await getAgentSettings({ botUserId: 0n }, botId)).settings?.defaultOutputMode).toBe(AgentOutputMode.DETAILED)
    const pushed = await latestUserUpdate(botId)
    expect(pushed?.oneofKind === "userAgentSettings" ? pushed.userAgentSettings.settings?.revision : undefined).toBe(2n)

    // Reading needs a grant; changing needs CONFIGURE.
    await rejects(getAgentSettings({ botUserId: BigInt(botId) }, teammateId), RpcError_Code.AGENT_GRANT_REQUIRED)
    await grant(teammateId, [AgentGrantOperation.INVOKE])
    expect((await getAgentSettings({ botUserId: BigInt(botId) }, teammateId)).settings?.revision).toBe(2n)
    await rejects(updateAgentSettings({ botUserId: BigInt(botId), defaultOutputMode: AgentOutputMode.FRIENDLY }, teammateId), RpcError_Code.AGENT_GRANT_REQUIRED)
    await rejects(updateAgentSettings({ botUserId: BigInt(botId), defaultOutputMode: 9 as AgentOutputMode }, ownerId), RpcError_Code.BAD_REQUEST)
    // Grantees get the change too.
    await updateAgentSettings({ botUserId: BigInt(botId), defaultOutputMode: AgentOutputMode.FRIENDLY }, ownerId)
    const granteeUpdate = await latestUserUpdate(teammateId)
    expect(granteeUpdate?.oneofKind === "userAgentSettings" ? granteeUpdate.userAgentSettings.settings?.defaultOutputMode : undefined)
      .toBe(AgentOutputMode.FRIENDLY)

    // A runtime reported later starts from the settings.
    const reported = await reportAgentRuntime({ provider: AgentSessionProvider.CODEX, status: 1 }, botId)
    expect(reported.runtime?.defaultOutputMode).toBe(AgentOutputMode.FRIENDLY)

    // Users and unowned bots have no settings.
    await rejects(getAgentSettings({ botUserId: 0n }, ownerId), RpcError_Code.USER_ID_INVALID)
  })

  test("legacy user grant upserts keep working after subject expansion", async () => {
    // The deployed predecessor supplies no partial-index predicate.
    const legacyGrant = (operations: number) => db.insert(agentGrants).values({
      botUserId: botId, subjectUserId: teammateId, operations, grantedBy: ownerId, revision: 1n,
    }).onConflictDoUpdate({
      target: [agentGrants.botUserId, agentGrants.subjectUserId],
      set: { operations },
    }).returning()
    const [first] = await legacyGrant(1)
    const [updated] = await legacyGrant(3)
    expect(updated?.id).toBe(first?.id)
    expect(updated?.operations).toBe(3)
    expect((await listAgentGrants({ botUserId: BigInt(botId) }, ownerId)).grants).toHaveLength(1)
  })

  test("legacy server writes preserve settings during rollout and rollback", async () => {
    await reportAgentRuntime({ provider: AgentSessionProvider.CODEX, status: 1 }, botId)
    await updateAgentSettings({ botUserId: BigInt(botId), defaultOutputMode: AgentOutputMode.FRIENDLY }, ownerId)

    // The deployed predecessor changes only the runtime table.
    await db.update(agentRuntimes).set({ defaultOutputMode: AgentOutputMode.DETAILED, updatedAt: new Date() })
      .where(eq(agentRuntimes.botUserId, botId))
    const changed = await getAgentSettings({ botUserId: 0n }, botId)
    expect([changed.settings?.defaultOutputMode, changed.settings?.revision])
      .toEqual([AgentOutputMode.DETAILED, 2n])

    await db.update(agentRuntimes).set({ defaultOutputMode: AgentOutputMode.UNSPECIFIED, updatedAt: new Date() })
      .where(eq(agentRuntimes.botUserId, botId))
    expect((await getAgentSettings({ botUserId: 0n }, botId)).settings?.defaultOutputMode)
      .toBe(AgentOutputMode.UNSPECIFIED)

    // The new setter's own mirror write does not increment the revision twice.
    const saved = await updateAgentSettings({ botUserId: BigInt(botId), defaultOutputMode: AgentOutputMode.FRIENDLY }, ownerId)
    expect(saved.settings?.revision).toBe(4n)
  })

  test("a legacy first heartbeat inherits a bot's existing settings", async () => {
    await updateAgentSettings({ botUserId: BigInt(botId), defaultOutputMode: AgentOutputMode.FRIENDLY }, ownerId)
    const [runtime] = await db.insert(agentRuntimes).values({
      botUserId: botId, provider: AgentSessionProvider.CODEX, status: 1, lastSeenAt: new Date(),
    }).returning()
    expect(runtime?.defaultOutputMode).toBe(AgentOutputMode.FRIENDLY)
    expect((await getAgentSettings({ botUserId: 0n }, botId)).settings?.revision).toBe(1n)
  })

  test("a legacy setter creates settings when the runtime used its default", async () => {
    await reportAgentRuntime({ provider: AgentSessionProvider.CODEX, status: 1 }, botId)
    expect((await getAgentSettings({ botUserId: 0n }, botId)).settings?.revision).toBe(0n)
    await db.update(agentRuntimes).set({ defaultOutputMode: AgentOutputMode.FRIENDLY, updatedAt: new Date() })
      .where(eq(agentRuntimes.botUserId, botId))
    const changed = await getAgentSettings({ botUserId: 0n }, botId)
    expect([changed.settings?.defaultOutputMode, changed.settings?.revision])
      .toEqual([AgentOutputMode.FRIENDLY, 1n])
  })

  test("bots can declare the output mode capability", () => {
    const [stored] = normalizeBotCapabilities([{ kind: BotCapability_Kind.OUTPUT_MODE, version: 1 }])
    expect(stored && toProtocolBotCapability({ kind: stored.kind, version: stored.version, payload: null })).toEqual({ kind: BotCapability_Kind.OUTPUT_MODE, version: 1, agentConfiguration: undefined })
    expect(() => normalizeBotCapabilities([{ kind: BotCapability_Kind.OUTPUT_MODE, version: 2 }])).toThrow()
  })

  test("a default output mode change reaches the agent's chat members", async () => {
    await setAgentParticipation({ peerId: peer, botUserId: BigInt(botId), mode: AgentParticipationMode.ACTIVE }, botId)
    await reportAgentRuntime({ provider: AgentSessionProvider.CODEX, status: 1, executablePath: "/opt/codex" }, botId)
    await updateAgentSettings({ botUserId: BigInt(botId), defaultOutputMode: AgentOutputMode.FRIENDLY }, ownerId)
    const [row] = await db.select().from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, teammateId)))
      .orderBy(desc(updates.seq)).limit(1)
    const payload = row ? UpdatesModel.decrypt(row).payload.update : undefined
    const runtime = payload?.oneofKind === "userAgentRuntime" ? payload.userAgentRuntime.runtime : undefined
    expect(runtime?.defaultOutputMode).toBe(AgentOutputMode.FRIENDLY)
    // Members get the status-only view.
    expect(runtime?.executablePath).toBeUndefined()
  })

  test("a lapsed heartbeat is published once to the owner and the agent's chat members", async () => {
    await setAgentParticipation({ peerId: peer, botUserId: BigInt(botId), mode: AgentParticipationMode.ACTIVE }, botId)
    await reportAgentRuntime({ provider: AgentSessionProvider.CODEX, status: 1, executablePath: "/opt/codex" }, botId)
    await db.update(agentRuntimes).set({ lastSeenAt: new Date(Date.now() - 10 * 60_000) }).where(eq(agentRuntimes.botUserId, botId))

    expect(await sweepLapsedAgentRuntimes()).toBe(1)
    expect(await sweepLapsedAgentRuntimes()).toBe(0)

    const latestRuntime = async (userId: number) => {
      const [row] = await db.select().from(updates)
        .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, userId)))
        .orderBy(desc(updates.seq)).limit(1)
      const payload = row ? UpdatesModel.decrypt(row).payload.update : undefined
      return payload?.oneofKind === "userAgentRuntime" ? payload.userAgentRuntime.runtime : undefined
    }
    const forOwner = await latestRuntime(ownerId)
    const forTeammate = await latestRuntime(teammateId)
    expect(forOwner?.status).toBe(2)
    expect(forOwner?.executablePath).toBe("/opt/codex")
    expect(forTeammate?.status).toBe(2)
    // Members see status, never the owner's local paths.
    expect(forTeammate?.executablePath).toBeUndefined()
    expect(await latestRuntime(strangerId)).toBeUndefined()
  })

  test("one work per thread and bot, moved into a subthread with its identity", async () => {
    const connect = (sessionRef: string, chat: InputPeer = peer) => connectAgentSession({
      peerId: chat,
      botUserId: BigInt(botId),
      provider: AgentSessionProvider.CODEX,
      instanceRef: "codex-installation",
      sessionRef,
      relation: 0,
    }, ownerId)
    const work = (await connect("first")).agentSession!
    // /new creates a new thread, so a second work in this thread is refused.
    await rejects(connect("second"), RpcError_Code.BAD_REQUEST)

    const sub = await testUtils.createChat(null, "Subthread", "thread", false, ownerId)
    if (!sub) throw new Error("subthread not created")
    await db.update(chats).set({ parentChatId: chatId }).where(eq(chats.id, sub.id))
    await Promise.all([ownerId, botId].map((id) => testUtils.addParticipant(sub.id, id)))
    const subPeer: InputPeer = { type: { oneofKind: "chat", chat: { chatId: BigInt(sub.id) } } }

    await rejects(moveAgentSession({ agentSessionId: work.id, destinationPeerId: subPeer }, teammateId), RpcError_Code.BAD_REQUEST)
    const moved = await moveAgentSession({ agentSessionId: work.id, destinationPeerId: subPeer }, botId)
    expect(moved.moved).toBe(true)
    expect(moved.agentSession?.id).toBe(work.id)
    expect(moved.agentSession?.parentChatId).toBe(BigInt(chatId))
    expect(moved.agentSession?.state?.revision).toBeGreaterThan(work.state?.revision ?? 0n)
    // A retry converges without advancing the ordering again.
    const retried = await moveAgentSession({ agentSessionId: work.id, destinationPeerId: subPeer }, botId)
    expect(retried.moved).toBe(false)
    expect(retried.agentSession?.state?.revision).toBe(moved.agentSession?.state?.revision)
    const grandchild = await testUtils.createChat(null, "Nested work", "thread", false, ownerId)
    if (!grandchild) throw new Error("nested thread not created")
    await db.update(chats).set({ parentChatId: sub.id }).where(eq(chats.id, grandchild.id))
    await Promise.all([ownerId, botId].map((id) => testUtils.addParticipant(grandchild.id, id)))
    const nestedPeer: InputPeer = { type: { oneofKind: "chat", chat: { chatId: BigInt(grandchild.id) } } }
    const nested = await moveAgentSession({ agentSessionId: work.id, destinationPeerId: nestedPeer }, botId)
    expect(nested.agentSession?.state?.revision).toBeGreaterThan(moved.agentSession?.state?.revision ?? 0n)
    // The native identity now resolves to the subthread, and the parent is free again.
    expect((await connect("first", nestedPeer)).state).toBe(2)
    expect((await getAgentSession({ peerId: peer, botUserId: BigInt(botId) }, ownerId)).connection).toBeUndefined()
    // Moves only go into a subthread of the work's current chat.
    await rejects(moveAgentSession({ agentSessionId: work.id, destinationPeerId: peer }, botId), RpcError_Code.BAD_REQUEST)
  })
})
