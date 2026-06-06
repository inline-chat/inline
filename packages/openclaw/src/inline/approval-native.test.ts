import { describe, expect, it, vi } from "vitest"
import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import type { ExecApprovalRequest } from "openclaw/plugin-sdk/approval-runtime"
import { inlineApprovalNativeRuntime } from "./approval-handler.runtime"
import { inlineApprovalCapability } from "./approval-native"
import {
  getInlineExecApprovalApprovers,
  isInlineExecApprovalClientEnabled,
} from "./exec-approvals"

const SET_BOT_PRESENCE_STATE = 59
const BOT_PRESENCE_IDLE = 2
const BOT_PRESENCE_WAITING = 7

function buildExecRequest(overrides?: Partial<ExecApprovalRequest["request"]>): ExecApprovalRequest {
  return {
    id: "approval-123456",
    request: {
      command: "pwd",
      agentId: "main",
      sessionKey: "main:inline:chat:7",
      turnSourceChannel: "inline",
      turnSourceTo: "chat:7",
      ...overrides,
    },
    createdAtMs: 1_700_000_000_000,
    expiresAtMs: 1_700_000_060_000,
  }
}

describe("inline/native approvals", () => {
  it("resolves Inline approvers from execApprovals and owner fallback", () => {
    const cfg = {
      commands: {
        ownerAllowFrom: ["user:61", "inline:user:62", "chat:63"],
      },
      channels: {
        inline: {
          token: "token",
          execApprovals: {
            approvers: [51, "user:52", "inline:user:53", "chat:54", "accessGroup:ops"],
          },
        },
      },
    } as OpenClawConfig

    expect(getInlineExecApprovalApprovers({ cfg })).toEqual(["51", "52", "53"])
    expect(
      getInlineExecApprovalApprovers({
        cfg: {
          commands: cfg.commands,
          channels: {
            inline: {
              token: "token",
            },
          },
        } as OpenClawConfig,
      }),
    ).toEqual(["61", "62"])
  })

  it("exposes native delivery surfaces and approver-only auth", async () => {
    const cfg = {
      channels: {
        inline: {
          token: "token",
          execApprovals: {
            approvers: ["51"],
            target: "both",
          },
        },
      },
    } as OpenClawConfig
    const request = buildExecRequest({ turnSourceThreadId: "8" })

    expect(isInlineExecApprovalClientEnabled({ cfg })).toBe(true)
    expect(
      inlineApprovalCapability.authorizeActorAction?.({
        cfg,
        accountId: "default",
        senderId: "user:51",
        action: "approve",
        approvalKind: "exec",
      }),
    ).toEqual({ authorized: true })
    expect(
      inlineApprovalCapability.authorizeActorAction?.({
        cfg,
        accountId: "default",
        senderId: "chat:51",
        action: "approve",
        approvalKind: "plugin",
      }),
    ).toMatchObject({ authorized: false })

    expect(
      inlineApprovalCapability.native?.describeDeliveryCapabilities?.({
        cfg,
        accountId: "default",
        approvalKind: "exec",
        request,
      }),
    ).toMatchObject({
      enabled: true,
      preferredSurface: "both",
      supportsOriginSurface: true,
      supportsApproverDmSurface: true,
      notifyOriginWhenDmOnly: true,
    })
    expect(
      await inlineApprovalCapability.native?.resolveOriginTarget?.({
        cfg,
        accountId: "default",
        approvalKind: "exec",
        request,
      }),
    ).toEqual({ to: "chat:7", threadId: "8" })
    expect(
      await inlineApprovalCapability.native?.resolveApproverDmTargets?.({
        cfg,
        accountId: "default",
        approvalKind: "exec",
        request,
      }),
    ).toEqual([{ to: "user:51" }])
  })

  it("renders, delivers, and clears Inline approval buttons", async () => {
    const sendTyping = vi.fn(async () => {})
    const sendMessage = vi.fn(async () => ({ messageId: 9001n }))
    const invokeRaw = vi.fn(async () => ({ oneofKind: "editMessage", editMessage: {} }))
    const cfg = {
      channels: {
        inline: {
          token: "token",
          capabilities: { replyThreads: true },
          execApprovals: {
            approvers: ["51"],
          },
        },
      },
    } as OpenClawConfig
    const context = {
      client: {
        sendTyping,
        sendMessage,
        invokeRaw,
      },
      parseMarkdown: false,
    }
    const request = buildExecRequest()
    const view = {
      approvalId: request.id,
      approvalKind: "exec",
      phase: "pending",
      title: "Exec approval required",
      metadata: [],
      commandText: "pwd",
      actions: [
        {
          decision: "allow-once",
          label: "Allow Once",
          style: "primary",
          command: `/approve ${request.id} allow-once`,
        },
        {
          decision: "deny",
          label: "Deny",
          style: "danger",
          command: `/approve ${request.id} deny`,
        },
      ],
      expiresAtMs: request.expiresAtMs,
    } as any

    const pendingPayload = await inlineApprovalNativeRuntime.presentation.buildPendingPayload({
      cfg,
      accountId: "default",
      context,
      request,
      approvalKind: "exec",
      nowMs: request.createdAtMs,
      view,
    })
    expect(pendingPayload.text).toContain("Approval required.")
    expect(pendingPayload.actions?.rows[0]?.actions[0]?.text).toBe("Allow Once")
    expect(
      pendingPayload.actions?.rows[0]?.actions[0]?.action.oneofKind,
    ).toBe("callback")

    const prepared = await inlineApprovalNativeRuntime.transport.prepareTarget({
      cfg,
      accountId: "default",
      context,
      request,
      approvalKind: "exec",
      view,
      pendingPayload,
      plannedTarget: {
        surface: "origin",
        target: { to: "chat:7", threadId: "8" },
      } as any,
    })
    expect(prepared?.target).toMatchObject({
      sendTarget: { chatId: 8n },
      typingChatId: 8n,
    })

    const entry = await inlineApprovalNativeRuntime.transport.deliverPending({
      cfg,
      accountId: "default",
      context,
      request,
      approvalKind: "exec",
      view,
      pendingPayload,
      plannedTarget: {
        surface: "origin",
        target: { to: "chat:7", threadId: "8" },
      } as any,
      preparedTarget: prepared!.target,
    })
    expect(sendTyping).toHaveBeenCalledWith({ chatId: 8n, typing: true })
    expect(sendTyping).toHaveBeenCalledWith({ chatId: 8n, typing: false })
    expect(invokeRaw).toHaveBeenCalledWith(
      SET_BOT_PRESENCE_STATE,
      expect.objectContaining({
        oneofKind: "setBotPresenceState",
        setBotPresenceState: expect.objectContaining({
          peerId: expect.objectContaining({
            type: expect.objectContaining({
              oneofKind: "chat",
              chat: { chatId: 8n },
            }),
          }),
          state: { kind: BOT_PRESENCE_WAITING },
        }),
      }),
    )
    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        chatId: 8n,
        text: pendingPayload.text,
        actions: pendingPayload.actions,
        parseMarkdown: false,
      }),
    )
    expect(entry?.messageId).toBe(9001n)

    await inlineApprovalNativeRuntime.interactions?.clearPendingActions?.({
      cfg,
      accountId: "default",
      context,
      entry: entry!,
      phase: "resolved",
    })
    expect(invokeRaw).toHaveBeenCalledWith(
      expect.any(Number),
      expect.objectContaining({
        oneofKind: "editMessage",
        editMessage: expect.objectContaining({
          messageId: 9001n,
          actions: { rows: [] },
          parseMarkdown: false,
        }),
      }),
    )
    expect(invokeRaw).toHaveBeenCalledWith(
      SET_BOT_PRESENCE_STATE,
      expect.objectContaining({
        oneofKind: "setBotPresenceState",
        setBotPresenceState: expect.objectContaining({
          peerId: expect.objectContaining({
            type: expect.objectContaining({
              oneofKind: "chat",
              chat: { chatId: 8n },
            }),
          }),
          state: { kind: BOT_PRESENCE_IDLE },
        }),
      }),
    )
  })
})
