import { describe, expect, it, vi } from "vitest"
import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import type { ExecApprovalRequest } from "openclaw/plugin-sdk/approval-runtime"
import { inlineApprovalNativeRuntime } from "./approval-handler.runtime"
import { inlineApprovalCapability } from "./approval-native"
import {
  getInlineExecApprovalApprovers,
  isInlineExecApprovalClientEnabled,
  shouldHandleInlineExecApprovalRequest,
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
      turnSourceChannel: "inline",
      turnSourceAccountId: "default",
      turnSourceTo: "chat:7",
      ...overrides,
    },
    createdAtMs: 1_700_000_000_000,
    expiresAtMs: 1_700_000_060_000,
  }
}

describe("inline/native approvals", () => {
  it("renders system change approvals with the host's exact decision commands", async () => {
    const request = {
      ...buildExecRequest(),
      approvalKind: "system-agent",
      request: { ...buildExecRequest().request, proposalHash: "proposal-1" },
    } as any
    const view = {
      approvalKind: "system-agent", phase: "pending", operationSummary: "Enable the requested integration",
      agentId: "main", actions: [
        { decision: "allow-once", label: "Approve", command: `/approve ${request.id} allow-once` },
        { decision: "deny", label: "Deny", command: `/approve ${request.id} deny` },
      ],
    } as any
    const payload = await inlineApprovalNativeRuntime.presentation.buildPendingPayload({
      cfg: {} as OpenClawConfig, request, approvalKind: "system-agent" as any,
      nowMs: request.createdAtMs, view,
    })
    expect(inlineApprovalNativeRuntime.eventKinds).toContain("system-agent")
    expect(payload.text).toContain("OpenClaw change requires approval")
    expect(payload.text).toContain(view.operationSummary)
    expect(payload.text).not.toContain("Exec approval")
    expect(payload.actions?.rows[0]?.actions.map(action => action.text)).toEqual(["Approve", "Deny"])
    for (const [index, action] of (payload.actions?.rows[0]?.actions ?? []).entries()) {
      expect(action.action.oneofKind).toBe("callback")
      if (action.action.oneofKind === "callback") {
        expect(Buffer.from(action.action.callback.data).toString()).toBe(view.actions[index].command)
      }
    }
    await expect(inlineApprovalNativeRuntime.presentation.buildPendingPayload({
      cfg: {} as OpenClawConfig, request, approvalKind: "system-agent" as any,
      nowMs: request.createdAtMs, view: { ...view, approvalKind: "exec" },
    })).rejects.toThrow("request and view kinds do not match")
  })

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
    // Only the async (worker-owned) surfaces are registered.
    for (const legacySurface of ["authorizeActorAction", "native", "nativeRuntime"] as const) {
      expect(inlineApprovalCapability[legacySurface]).toBeUndefined()
    }
    expect(inlineApprovalCapability.nativeRuntimeAsync).toBeDefined()
    await expect(
      inlineApprovalCapability.authorizeActorActionAsync!({
        cfg,
        accountId: "default",
        senderId: "user:51",
        action: "approve",
        approvalKind: "exec",
      }),
    ).resolves.toEqual({ authorized: true })
    await expect(
      inlineApprovalCapability.authorizeActorActionAsync!({
        cfg,
        accountId: "default",
        senderId: "chat:51",
        action: "approve",
        approvalKind: "plugin",
      }),
    ).resolves.toMatchObject({ authorized: false })

    await expect(
      inlineApprovalCapability.nativeAsync!.describeDeliveryCapabilities({
        cfg,
        accountId: "default",
        approvalKind: "exec",
        request,
      }),
    ).resolves.toMatchObject({
      enabled: true,
      preferredSurface: "both",
      supportsOriginSurface: true,
      supportsApproverDmSurface: true,
      notifyOriginWhenDmOnly: true,
    })
    expect(
      await inlineApprovalCapability.nativeAsync!.resolveOriginTarget!({
        cfg,
        accountId: "default",
        approvalKind: "exec",
        request,
      }),
    ).toEqual({ to: "chat:7", threadId: "8" })
    expect(
      await inlineApprovalCapability.nativeAsync!.resolveApproverDmTargets!({
        cfg,
        accountId: "default",
        approvalKind: "exec",
        request,
      }),
    ).toEqual([{ to: "user:51" }])
  })

  it.each([
    {
      name: "prefixed chat target keeps its thread",
      overrides: { turnSourceTo: "inline:chat:7", turnSourceThreadId: "8" },
      expected: { to: "chat:7", threadId: "8" },
    },
    {
      name: "numeric thread id is normalized",
      overrides: { turnSourceTo: "chat:7", turnSourceThreadId: 9 as unknown as string },
      expected: { to: "chat:7", threadId: "9" },
    },
    {
      name: "DM origin never carries a thread",
      overrides: { turnSourceTo: "user:51", turnSourceThreadId: "8" },
      expected: { to: "user:51" },
    },
    {
      name: "non-numeric target has no Inline origin",
      overrides: { turnSourceTo: "chat:general", turnSourceThreadId: undefined },
      expected: null,
    },
    {
      name: "another channel's turn has no Inline origin",
      overrides: { turnSourceChannel: "telegram", turnSourceTo: "chat:7", sessionKey: undefined },
      expected: null,
    },
  ])("routes the approval card's origin: $name", async ({ overrides, expected }) => {
    const cfg = {
      channels: { inline: { token: "token", execApprovals: { approvers: ["51"], target: "both" } } },
    } as OpenClawConfig
    const request = buildExecRequest(overrides as Partial<ExecApprovalRequest["request"]>)

    const target = await inlineApprovalCapability.nativeAsync!.resolveOriginTarget!({
      cfg,
      accountId: "default",
      approvalKind: "exec",
      request,
    })

    expect(target).toEqual(expected)
  })

  it("falls back to the Inline session when the request has no turn source", async () => {
    const cfg = {
      channels: { inline: { token: "token", execApprovals: { approvers: ["51"], target: "both" } } },
    } as OpenClawConfig
    const request = buildExecRequest({
      turnSourceChannel: undefined,
      turnSourceAccountId: undefined,
      turnSourceTo: undefined,
      sessionKey: "agent:main:inline:group:7",
    } as Partial<ExecApprovalRequest["request"]>)

    const target = await inlineApprovalCapability.nativeAsync!.resolveOriginTarget!({
      cfg,
      accountId: "default",
      approvalKind: "exec",
      request,
    })

    expect(target).toEqual({ to: "chat:7" })
  })

  it("tells a non-approver that Inline exec approvals are off for this bot", () => {
    const disabled = { channels: { inline: { token: "token", execApprovals: { enabled: false } } } } as OpenClawConfig
    const enabled = {
      channels: { inline: { token: "token", execApprovals: { approvers: ["51"] } } },
    } as OpenClawConfig

    expect(
      inlineApprovalCapability.resolveApproveCommandBehavior!({
        cfg: disabled,
        accountId: "default",
        senderId: "user:77",
        approvalKind: "exec",
      } as any),
    ).toMatchObject({ kind: "reply", text: expect.stringContaining("not enabled") })
    expect(
      inlineApprovalCapability.resolveApproveCommandBehavior!({
        cfg: enabled,
        accountId: "default",
        senderId: "user:77",
        approvalKind: "exec",
      } as any),
    ).toBeUndefined()
    expect(
      inlineApprovalCapability.resolveApproveCommandBehavior!({
        cfg: disabled,
        accountId: "default",
        senderId: "user:77",
        approvalKind: "plugin",
      } as any),
    ).toBeUndefined()
  })

  it("matches approval requests to Inline accounts asynchronously", async () => {
    const accounts = {
      a: { token: "token-a", execApprovals: { approvers: ["51"] } },
      b: { token: "token-b", execApprovals: { approvers: ["52"] } },
    }
    const cfg = { channels: { inline: { accounts } } } as unknown as OpenClawConfig
    const handles = (config: OpenClawConfig, accountId: string, request: ExecApprovalRequest) =>
      shouldHandleInlineExecApprovalRequest({ cfg: config, accountId, request })

    // Bound turn-source account wins.
    const bound = buildExecRequest({ turnSourceAccountId: "b" })
    const boundResult = handles(cfg, "b", bound)
    expect(boundResult).toBeInstanceOf(Promise)
    await expect(boundResult).resolves.toBe(true)
    await expect(handles(cfg, "a", bound)).resolves.toBe(false)

    // Explicit Inline forwarding targets scope delivery to their accounts.
    const targeted = {
      ...cfg,
      approvals: {
        exec: {
          enabled: true,
          mode: "targets",
          targets: [{ channel: "inline", to: "user:52", accountId: "b" }],
        },
      },
    } as unknown as OpenClawConfig
    const unbound = buildExecRequest({ turnSourceAccountId: undefined })
    await expect(handles(targeted, "b", unbound)).resolves.toBe(true)
    await expect(handles(targeted, "a", unbound)).resolves.toBe(false)

    // Foreign-channel requests without a bound account only route when exactly
    // one Inline account is eligible.
    const foreign = buildExecRequest({
      turnSourceChannel: "slack",
      turnSourceAccountId: undefined,
      turnSourceTo: "channel:C1",
    })
    await expect(handles(cfg, "a", foreign)).resolves.toBe(false)
    const single = {
      channels: { inline: { accounts: { a: accounts.a } } },
    } as unknown as OpenClawConfig
    await expect(handles(single, "a", foreign)).resolves.toBe(true)

    // The runtime availability gate awaits the same account matching.
    const context = { client: {} }
    await expect(
      Promise.resolve(inlineApprovalNativeRuntime.availability.shouldHandle({
        cfg, accountId: "a", context, request: bound, approvalKind: "exec",
      })),
    ).resolves.toBe(false)
    await expect(
      Promise.resolve(inlineApprovalNativeRuntime.availability.shouldHandle({
        cfg, accountId: "b", context, request: bound, approvalKind: "exec",
      })),
    ).resolves.toBe(true)
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
