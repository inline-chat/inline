import os from "node:os"
import path from "node:path"
import { access, mkdir, mkdtemp, symlink, writeFile } from "node:fs/promises"
import { describe, expect, it, vi } from "vitest"
import type { OpenClawConfig, PluginRuntime } from "openclaw/plugin-sdk"

function mockRealtimeSdk(overrides: Record<string, unknown>): void {
  vi.doMock("@inline-chat/realtime-sdk", async () => {
    const actual = await vi.importActual<Record<string, unknown>>("@inline-chat/realtime-sdk")
    return {
      ...actual,
      ...overrides,
    }
  })
}

function mockOpenClawMediaSdk(overrides?: {
  loadWebMedia?: ReturnType<typeof vi.fn>
  detectMime?: ReturnType<typeof vi.fn>
  extensionForMime?: ReturnType<typeof vi.fn>
}): void {
  vi.doMock("openclaw/plugin-sdk/web-media", async () => {
    const actual = await vi.importActual<Record<string, unknown>>("openclaw/plugin-sdk/web-media")
    return {
      ...actual,
      ...(overrides?.loadWebMedia ? { loadWebMedia: overrides.loadWebMedia } : {}),
    }
  })
  vi.doMock("openclaw/plugin-sdk/media-runtime", async () => {
    const actual = await vi.importActual<Record<string, unknown>>("openclaw/plugin-sdk/media-runtime")
    return {
      ...actual,
      ...(overrides?.detectMime ? { detectMime: overrides.detectMime } : {}),
      ...(overrides?.extensionForMime ? { extensionForMime: overrides.extensionForMime } : {}),
    }
  })
}

async function setInlineTestRuntime(options?: {
  loadWebMedia?: ReturnType<typeof vi.fn>
  detectMime?: ReturnType<typeof vi.fn>
  stateDir?: string
}): Promise<void> {
  const runtimeMod = await import("../runtime")
  runtimeMod.setInlineRuntime({
    version: "test",
    state: { resolveStateDir: () => options?.stateDir ?? "/tmp" },
    channel: { text: { chunkMarkdownText: (text: string) => [text] } },
    media: {
      loadWebMedia:
        options?.loadWebMedia ??
        vi.fn(async () => ({
          buffer: Buffer.from([1, 2, 3]),
          contentType: "application/octet-stream",
          kind: "document",
          fileName: "attachment.bin",
        })),
      detectMime: options?.detectMime ?? vi.fn(async () => undefined),
    },
  } as unknown as PluginRuntime)
}

describe("inline/channel", () => {
  it("declares platform thread support", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")

    expect(inlineChannelPlugin.meta.selectionLabel).toBe("Inline (Bot API)")
    expect(inlineChannelPlugin.meta.markdownCapable).toBe(true)
    expect(inlineChannelPlugin.commands).toMatchObject({
      nativeCommandsAutoEnabled: true,
      nativeSkillsAutoEnabled: true,
    })
    expect(inlineChannelPlugin.agentPrompt?.inboundFormattingHints?.({})).toEqual({
      text_markup: "inline_markdown",
      rules: expect.arrayContaining([
        "Prefer bullet lists over markdown tables.",
        "Use plain URLs or markdown links; do not wrap bare URLs in inline code or backticks.",
      ]),
    })
    expect(
      inlineChannelPlugin.agentPrompt?.reactionGuidance?.({
        cfg: {
          channels: {
            inline: {
              token: "token",
            },
          },
        } as OpenClawConfig,
      }),
    ).toEqual({ level: "minimal", channelLabel: "Inline" })
    expect(
      inlineChannelPlugin.agentPrompt?.reactionGuidance?.({
        cfg: {
          channels: {
            inline: {
              token: "token",
              actions: { reactions: false },
            },
          },
        } as OpenClawConfig,
      }),
    ).toBeUndefined()
    expect(
      inlineChannelPlugin.agentPrompt?.messageToolCapabilities?.({
        cfg: {
          channels: {
            inline: {
              token: "token",
            },
          },
        } as OpenClawConfig,
      }),
    ).toContain("inlineButtons")
    expect(
      (inlineChannelPlugin.agentPrompt?.messageToolHints?.({
        cfg: {
          channels: {
            inline: {
              token: "token",
            },
          },
        } as OpenClawConfig,
      }) ?? []).join("\n"),
    ).toContain("Prefer Inline buttons/selects")
    expect(inlineChannelPlugin.commands?.buildModelsMenuChannelData?.({
      providers: [{ id: "openai", count: 2 }],
    })).toEqual({
      inline: {
        buttons: [[{ text: "openai (2)", callback_data: "mdl_list_openai_1" }]],
      },
    })
    expect(
      inlineChannelPlugin.agentPrompt?.messageToolCapabilities?.({
        cfg: {
          channels: {
            inline: {
              token: "token",
              actions: { send: false, reply: false, edit: false },
            },
          },
        } as OpenClawConfig,
      }),
    ).toEqual([])
    expect(
      inlineChannelPlugin.agentPrompt?.messageToolCapabilities?.({
        cfg: {
          channels: {
            inline: {
              token: "token",
              accounts: {
                quiet: {
                  token: "quiet-token",
                  actions: { send: false, reply: false, edit: false },
                },
              },
            },
          },
        } as OpenClawConfig,
        accountId: "quiet",
      }),
    ).toEqual([])
    expect(
      (inlineChannelPlugin.agentPrompt?.messageToolHints?.({
        cfg: {
          channels: {
            inline: {
              token: "token",
              accounts: {
                quiet: {
                  token: "quiet-token",
                  actions: { send: false, reply: false, edit: false },
                },
              },
            },
          },
        } as OpenClawConfig,
        accountId: "quiet",
      }) ?? []).join("\n"),
    ).not.toContain("Prefer Inline buttons/selects")
    expect(
      (inlineChannelPlugin.agentPrompt?.messageToolHints?.({
        cfg: {
          channels: {
            inline: {
              token: "token",
              actions: { reactions: false },
            },
          },
        } as OpenClawConfig,
        accountId: "default",
      }) ?? []).join("\n"),
    ).not.toContain("Inline reactions")
    expect(inlineChannelPlugin.commands?.buildModelsListChannelData?.({
      provider: "openai",
      models: ["gpt-4.1"],
      currentPage: 1,
      totalPages: 1,
    })).toEqual({
      inline: {
        buttons: [
          [{ text: "gpt-4.1", callback_data: "mdl_sel_openai/gpt-4.1" }],
          [{ text: "<< Back", callback_data: "mdl_back" }],
        ],
      },
    })
    expect(inlineChannelPlugin.commands?.buildModelsListChannelData?.({
      provider: "openai",
      models: ["gpt-4.1", "gpt-4.2", "gpt-4.3"],
      currentModel: "openai/gpt-4.2",
      currentPage: 2,
      totalPages: 3,
      pageSize: 1,
    })).toEqual({
      inline: {
        buttons: [
          [{ text: "gpt-4.2 ✓", callback_data: "mdl_sel_openai/gpt-4.2" }],
          [
            { text: "◀ Prev", callback_data: "mdl_list_openai_1" },
            { text: "2/3", callback_data: "mdl_list_openai_2" },
            { text: "Next ▶", callback_data: "mdl_list_openai_3" },
          ],
          [{ text: "<< Back", callback_data: "mdl_back" }],
        ],
      },
    })
    expect(inlineChannelPlugin.commands?.buildCommandsListChannelData?.({
      currentPage: 1,
      totalPages: 2,
      agentId: "main",
    })).toEqual({
      inline: {
        buttons: [
          [
            { text: "1/2", callback_data: "commands_page_noop:main" },
            { text: "Next ▶", callback_data: "commands_page_2:main" },
          ],
        ],
      },
    })
    expect(inlineChannelPlugin.capabilities.chatTypes).toEqual(["direct", "group"])
    expect(inlineChannelPlugin.capabilities.media).toBe(true)
    expect(inlineChannelPlugin.capabilities.reactions).toBe(true)
    expect(inlineChannelPlugin.capabilities.reply).toBe(true)
    expect(inlineChannelPlugin.capabilities.threads).toBe(true)
    expect(inlineChannelPlugin.threading).toBeDefined()
    expect(inlineChannelPlugin.setup).toBeDefined()
    expect(inlineChannelPlugin.setupWizard).toBeDefined()
    expect(inlineChannelPlugin.approvalCapability?.nativeRuntime).toBeDefined()
    expect(inlineChannelPlugin.approvalCapability?.native?.describeDeliveryCapabilities?.({
      cfg: {
        channels: {
          inline: {
            token: "token",
            execApprovals: {
              approvers: ["51"],
            },
          },
        },
      } as OpenClawConfig,
      accountId: "default",
      approvalKind: "exec",
      request: {
        id: "approval-1",
        request: {
          command: "pwd",
          turnSourceChannel: "inline",
          turnSourceTo: "chat:7",
        },
        createdAtMs: 1,
        expiresAtMs: 2,
      } as any,
    })).toMatchObject({
      enabled: true,
      preferredSurface: "approver-dm",
      supportsOriginSurface: true,
      supportsApproverDmSurface: true,
    })
    expect(inlineChannelPlugin.messaging?.transformReplyPayload?.({
      payload: {
        text: "See `https://example.com/docs`.",
      },
      cfg: {} as OpenClawConfig,
      accountId: "default",
    })).toEqual({
      text: "See https://example.com/docs.",
    })
    expect(inlineChannelPlugin.secrets?.secretTargetRegistryEntries?.map((entry) => entry.id)).toEqual([
      "channels.inline.accounts.*.token",
      "channels.inline.token",
    ])
    expect(inlineChannelPlugin.status?.collectStatusIssues).toBeDefined()
    expect(inlineChannelPlugin.status?.probeAccount).toBeDefined()
    expect(inlineChannelPlugin.gateway?.logoutAccount).toBeDefined()
    expect(inlineChannelPlugin.lifecycle?.onAccountConfigChanged).toBeDefined()
    expect(inlineChannelPlugin.lifecycle?.onAccountRemoved).toBeDefined()
    expect(inlineChannelPlugin.allowlist).toBeDefined()
    expect(inlineChannelPlugin.bindings).toBeDefined()
    expect(inlineChannelPlugin.outbound.presentationCapabilities).toEqual({
      supported: true,
      buttons: true,
      selects: true,
      context: true,
      divider: false,
    })
    expect(inlineChannelPlugin.outbound.extractMarkdownImages).toBe(true)
    expect(inlineChannelPlugin.outbound.preferFinalAssistantVisibleText).toBe(true)
    expect(inlineChannelPlugin.message).toMatchObject({
      id: "inline",
      live: {
        capabilities: {
          draftPreview: true,
          previewFinalization: true,
          progressUpdates: true,
        },
      },
    })
    expect(inlineChannelPlugin.message?.send?.text).toBeDefined()
    expect(inlineChannelPlugin.message?.send?.media).toBeDefined()
    expect(inlineChannelPlugin.message?.send?.payload).toBeDefined()
    expect(inlineChannelPlugin.messaging?.targetPrefixes).toEqual(["inline"])
    expect(inlineChannelPlugin.streaming?.blockStreamingCoalesceDefaults).toEqual({
      minChars: 1500,
      idleMs: 1000,
    })
  })

  it("resolves configured default outbound targets", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")
    const cfg = {
      channels: {
        inline: {
          token: "token",
          defaultTo: 51,
          accounts: {
            work: {
              token: "work-token",
              defaultTo: "chat:52",
            },
          },
        },
      },
    } as OpenClawConfig

    expect(inlineChannelPlugin.config.resolveDefaultTo?.({ cfg })).toBe("51")
    expect(inlineChannelPlugin.config.resolveDefaultTo?.({ cfg, accountId: "work" })).toBe(
      "chat:52",
    )
  })

  it("surfaces per-group sender allowlist overrides", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")
    const cfg = {
      channels: {
        inline: {
          token: "token",
          groupPolicy: "allowlist",
          groupAllowFrom: ["51"],
          groups: {
            "chat:88": {
              allowFrom: ["61", "accessGroup:operators"],
            },
            "*": {
              allowFrom: ["71"],
              requireMention: true,
            },
          },
        },
      },
    } as OpenClawConfig

    await expect(Promise.resolve(inlineChannelPlugin.allowlist?.readConfig?.({ cfg }))).resolves.toMatchObject({
      groupAllowFrom: ["51"],
      groupPolicy: "allowlist",
      groupOverrides: [
        { label: "chat:88", entries: ["61", "accessGroup:operators"] },
        { label: "*", entries: ["71"] },
      ],
    })
  })

  it("supports inline bindings normalization and parent matching", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")

    const compiled = inlineChannelPlugin.bindings?.compileConfiguredBinding({
      binding: {} as any,
      conversationId: "inline:123",
    } as any)
    expect(compiled).toEqual({ conversationId: "inline:chat:123" })

    const exact = inlineChannelPlugin.bindings?.matchInboundConversation({
      binding: {} as any,
      compiledBinding: compiled,
      conversationId: "chat:123",
      parentConversationId: undefined,
    } as any)
    expect(exact).toEqual({
      conversationId: "inline:chat:123",
      matchPriority: 2,
    })

    const parentMatch = inlineChannelPlugin.bindings?.matchInboundConversation({
      binding: {} as any,
      compiledBinding: compiled,
      conversationId: "inline:chat:555",
      parentConversationId: "inline:123",
    } as any)
    expect(parentMatch).toEqual({
      conversationId: "inline:chat:555",
      parentConversationId: "inline:chat:123",
      matchPriority: 1,
    })

    expect(inlineChannelPlugin.conversationBindings).toMatchObject({
      supportsCurrentConversationBinding: true,
      defaultTopLevelPlacement: "current",
    })
    expect(
      inlineChannelPlugin.conversationBindings?.resolveConversationRef?.({
        conversationId: "inline:123",
      }),
    ).toEqual({ conversationId: "inline:chat:123" })
    expect(
      inlineChannelPlugin.conversationBindings?.resolveConversationRef?.({
        conversationId: "inline:chat:555",
        parentConversationId: "inline:123",
      }),
    ).toEqual({
      conversationId: "inline:chat:555",
      parentConversationId: "inline:chat:123",
    })
    expect(
      inlineChannelPlugin.conversationBindings?.resolveConversationRef?.({
        conversationId: "inline:chat:123",
        threadId: "555",
      }),
    ).toEqual({
      conversationId: "inline:chat:555",
      parentConversationId: "inline:chat:123",
    })
  })

  it("provides explicit target parsing + chat-type inference for messaging", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")

    const user = inlineChannelPlugin.messaging?.parseExplicitTarget?.({ raw: "user:42" })
    const group = inlineChannelPlugin.messaging?.parseExplicitTarget?.({ raw: "inline:7" })
    const invalid = inlineChannelPlugin.messaging?.parseExplicitTarget?.({ raw: "bad-target" })

    expect(user).toEqual({ to: "user:42", chatType: "direct" })
    expect(group).toEqual({ to: "chat:7", chatType: "group" })
    expect(invalid).toBeNull()

    expect(inlineChannelPlugin.messaging?.inferTargetChatType?.({ to: "user:42" })).toBe("direct")
    expect(inlineChannelPlugin.messaging?.inferTargetChatType?.({ to: "chat:7" })).toBe("group")
    expect(inlineChannelPlugin.messaging?.resolveSessionTarget?.({ kind: "group", id: "7" })).toBe(
      "chat:7",
    )
    expect(
      inlineChannelPlugin.messaging?.resolveSessionTarget?.({ kind: "channel", id: "chat:8" }),
    ).toBe("chat:8")
    expect(
      inlineChannelPlugin.messaging?.resolveSessionConversation?.({
        kind: "group",
        rawId: "inline:chat:7",
      }),
    ).toEqual({
      id: "7",
      baseConversationId: "inline:chat:7",
      parentConversationCandidates: [],
    })
    expect(
      inlineChannelPlugin.messaging?.resolveSessionConversation?.({
        kind: "group",
        rawId: "7:thread:8",
      }),
    ).toEqual({
      id: "7",
      threadId: "8",
      baseConversationId: "inline:chat:7",
      parentConversationCandidates: ["inline:chat:7"],
    })
    expect(
      inlineChannelPlugin.messaging?.resolveInboundConversation?.({
        to: "inline:7",
        isGroup: true,
      }),
    ).toEqual({ conversationId: "inline:chat:7" })
    expect(
      inlineChannelPlugin.messaging?.resolveInboundConversation?.({
        to: "inline:chat:7",
        conversationId: "inline:chat:8",
        threadId: "8",
        isGroup: true,
      }),
    ).toEqual({
      conversationId: "inline:chat:8",
      parentConversationId: "inline:chat:7",
    })
    expect(
      inlineChannelPlugin.messaging?.resolveDeliveryTarget?.({ conversationId: "7" }),
    ).toEqual({ to: "chat:7" })
    expect(
      inlineChannelPlugin.messaging?.resolveDeliveryTarget?.({
        conversationId: "inline:chat:8",
        parentConversationId: "chat:7",
      }),
    ).toEqual({ to: "chat:7", threadId: "8" })
    expect(
      inlineChannelPlugin.messaging?.formatTargetDisplay?.({
        target: "bad-target",
      }),
    ).toBe("bad-target")
    expect(inlineChannelPlugin.messaging?.preserveHeartbeatThreadIdForGroupRoute).toBe(true)
  })

  it("sends heartbeat typing for Inline chat and reply-thread targets", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const sendTyping = vi.fn(async () => {})
    const close = vi.fn(async () => {})

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        sendTyping = sendTyping
        close = close
      },
    })

    const { inlineChannelPlugin } = await import("./channel")
    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
          capabilities: { replyThreads: true },
        },
      },
    } satisfies OpenClawConfig

    await inlineChannelPlugin.heartbeat?.sendTyping?.({
      cfg,
      to: "chat:7",
      accountId: "default",
      threadId: "8",
    })
    await inlineChannelPlugin.heartbeat?.clearTyping?.({
      cfg,
      to: "inline:7",
      accountId: "default",
      threadId: "8",
    })
    await inlineChannelPlugin.heartbeat?.sendTyping?.({
      cfg,
      to: "user:42",
      accountId: "default",
    })

    expect(sendTyping).toHaveBeenNthCalledWith(1, { chatId: 8n, typing: true })
    expect(sendTyping).toHaveBeenNthCalledWith(2, { chatId: 8n, typing: false })
    expect(sendTyping).toHaveBeenCalledTimes(2)
    expect(connect).toHaveBeenCalledTimes(2)
    expect(close).toHaveBeenCalledTimes(2)
  })

  it("canonicalizes outbound session routes for explicit Inline targets", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")

    const group = await inlineChannelPlugin.messaging?.resolveOutboundSessionRoute?.({
      cfg: {} as OpenClawConfig,
      agentId: "main",
      target: "chat:7",
    })
    const direct = await inlineChannelPlugin.messaging?.resolveOutboundSessionRoute?.({
      cfg: {
        session: {
          dmScope: "per-channel-peer",
        },
      } as OpenClawConfig,
      agentId: "main",
      target: "user:42",
    })
    const resolvedBareUser = await inlineChannelPlugin.messaging?.resolveOutboundSessionRoute?.({
      cfg: {
        session: {
          dmScope: "per-channel-peer",
        },
      } as OpenClawConfig,
      agentId: "main",
      target: "42",
      resolvedTarget: { kind: "user" },
    })

    expect(group).toEqual(
      expect.objectContaining({
        sessionKey: "agent:main:inline:group:7",
        baseSessionKey: "agent:main:inline:group:7",
        chatType: "group",
        from: "inline:chat:7",
        to: "chat:7",
        peer: { kind: "group", id: "7" },
      }),
    )
    expect(direct).toEqual(
      expect.objectContaining({
        sessionKey: "agent:main:inline:direct:42",
        baseSessionKey: "agent:main:inline:direct:42",
        chatType: "direct",
        from: "inline:42",
        to: "user:42",
        peer: { kind: "direct", id: "42" },
      }),
    )
    expect(resolvedBareUser).toEqual(expect.objectContaining({ peer: { kind: "direct", id: "42" } }))
  })

  it("keeps Inline reply-thread ids in outbound session route suffixes", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")

    const route = await inlineChannelPlugin.messaging?.resolveOutboundSessionRoute?.({
      cfg: {
        channels: {
          inline: {
            capabilities: {
              replyThreads: true,
            },
          },
        },
      } as OpenClawConfig,
      agentId: "main",
      target: "inline:7",
      threadId: "8",
    })

    expect(route).toEqual(
      expect.objectContaining({
        sessionKey: "agent:main:inline:group:7:thread:8",
        baseSessionKey: "agent:main:inline:group:7",
        threadId: "8",
        from: "inline:chat:7",
        to: "chat:7",
      }),
    )
  })

  it("config adapters support account enable/disable + delete", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")

    const baseCfg = {
      channels: {
        inline: {
          token: "token",
          accounts: {
            ops: {
              token: "ops-token",
            },
          },
        },
      },
    } satisfies OpenClawConfig

    const disabled = inlineChannelPlugin.config.setAccountEnabled?.({
      cfg: baseCfg,
      accountId: "ops",
      enabled: false,
    } as any)
    const resolvedDisabled = inlineChannelPlugin.config.resolveAccount(disabled as OpenClawConfig, "ops")
    expect(resolvedDisabled.enabled).toBe(false)

    const deleted = inlineChannelPlugin.config.deleteAccount?.({
      cfg: baseCfg,
      accountId: "ops",
    } as any)
    const ids = inlineChannelPlugin.config.listAccountIds(deleted as OpenClawConfig)
    expect(ids.includes("ops")).toBe(false)
    expect(
      inlineChannelPlugin.config.hasConfiguredState?.({
        cfg: {} as OpenClawConfig,
        env: { INLINE_BOT_TOKEN: "bot-token" } as NodeJS.ProcessEnv,
      }),
    ).toBe(true)
  })

  it("setup plugin stays on the setup-only surface", async () => {
    vi.resetModules()
    const { inlineSetupPlugin } = await import("./setup-plugin")

    expect(inlineSetupPlugin.id).toBe("inline")
    expect(inlineSetupPlugin.meta.selectionLabel).toBe("Inline (Bot API)")
    expect(inlineSetupPlugin.setup).toBeDefined()
    expect(inlineSetupPlugin.setupWizard).toBeDefined()
    expect(inlineSetupPlugin.doctor).toMatchObject({
      dmAllowFromMode: "topOrNested",
      groupModel: "hybrid",
      groupAllowFromFallbackToAllowFrom: false,
      warnOnEmptyGroupSenderAllowlist: true,
    })
    expect(inlineSetupPlugin.security?.collectAuditFindings).toBeDefined()
    expect(inlineSetupPlugin.config.hasConfiguredState?.({
      cfg: {} as OpenClawConfig,
      env: { INLINE_TOKEN: "token" } as NodeJS.ProcessEnv,
    })).toBe(true)
    expect(inlineSetupPlugin.gateway).toBeUndefined()
    expect(inlineSetupPlugin.outbound).toBeUndefined()
    expect(inlineSetupPlugin.threading).toBeUndefined()
  })

  it.runIf(process.platform !== "win32")("config inspection rejects unreadable tokenFile paths", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")
    const dir = await mkdtemp(path.join(os.tmpdir(), "inline-channel-inspect-"))
    const tokenPath = path.join(dir, "token.txt")
    const linkPath = path.join(dir, "token-link.txt")
    await writeFile(tokenPath, "file-token\n", "utf8")
    await symlink(tokenPath, linkPath)
    const cfg = {
      channels: {
        inline: {
          tokenFile: linkPath,
        },
      },
    } satisfies OpenClawConfig
    const account = inlineChannelPlugin.config.resolveAccount(cfg, "default")

    expect(account.configured).toBe(true)
    expect(inlineChannelPlugin.config.inspectAccount?.(cfg, "default")).toEqual(
      expect.objectContaining({
        configured: false,
        tokenSource: "file",
        tokenStatus: "configured_unavailable",
      }),
    )
    expect(inlineChannelPlugin.config.isConfigured?.(account, cfg)).toBe(false)
    expect(inlineChannelPlugin.config.unconfiguredReason?.(account, cfg)).toContain(
      "configured but unavailable",
    )
    expect(inlineChannelPlugin.config.describeAccount?.(account, cfg)).toEqual(
      expect.objectContaining({
        configured: false,
        tokenSource: "file",
      }),
    )

    const snapshot = inlineChannelPlugin.status?.buildAccountSnapshot?.({
      cfg,
      account,
      runtime: { running: false } as any,
    } as any)
    expect(snapshot).toEqual(
      expect.objectContaining({
        configured: false,
        tokenSource: "file",
      }),
    )
    expect(inlineChannelPlugin.status?.collectStatusIssues?.([snapshot as any])).toEqual([
      expect.objectContaining({
        kind: "config",
        message: "Inline account token is configured but unavailable.",
      }),
    ])
  })

  it("marks duplicate Inline token accounts as unconfigured and blocks startup", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")
    const cfg = {
      channels: {
        inline: {
          token: "shared-token",
          accounts: {
            ops: { token: "shared-token" },
          },
        },
      },
    } satisfies OpenClawConfig
    const account = inlineChannelPlugin.config.resolveAccount(cfg, "ops")

    expect(account.configured).toBe(true)
    expect(inlineChannelPlugin.config.isConfigured?.(account, cfg)).toBe(false)
    expect(inlineChannelPlugin.config.unconfiguredReason?.(account, cfg)).toBe(
      'Duplicate Inline bot token: account "ops" shares a token with account "default". Keep one owner account per Inline bot token.',
    )
    expect(inlineChannelPlugin.config.describeAccount?.(account, cfg)).toEqual(
      expect.objectContaining({
        configured: false,
        tokenSource: "config",
      }),
    )

    const snapshot = inlineChannelPlugin.status?.buildAccountSnapshot?.({
      cfg,
      account,
      runtime: { running: false } as any,
    } as any)
    expect(snapshot).toEqual(
      expect.objectContaining({
        configured: false,
        lastError:
          'Duplicate Inline bot token: account "ops" shares a token with account "default". Keep one owner account per Inline bot token.',
      }),
    )
    expect(inlineChannelPlugin.status?.collectStatusIssues?.([snapshot as any])).toEqual([
      expect.objectContaining({
        kind: "config",
        message:
          'Duplicate Inline bot token: account "ops" shares a token with account "default". Keep one owner account per Inline bot token.',
      }),
    ])

    await expect(
      inlineChannelPlugin.gateway?.startAccount?.({
        cfg,
        account,
        runtime: {} as any,
        abortSignal: new AbortController().signal,
        getStatus: () => ({}),
        setStatus: vi.fn(),
        log: {
          info: vi.fn(),
          warn: vi.fn(),
          error: vi.fn(),
        },
      } as any),
    ).rejects.toThrow("Duplicate Inline bot token")
  })

  it("surfaces reaction notification settings in account inspection and status", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")
    const cfg = {
      channels: {
        inline: {
          token: "token",
          reactionNotifications: "allowlist",
          reactionAllowlist: ["51"],
        },
      },
    } satisfies OpenClawConfig
    const account = inlineChannelPlugin.config.resolveAccount(cfg, "default")

    expect(account).toEqual(
      expect.objectContaining({
        reactionNotifications: "allowlist",
        reactionAllowlist: ["51"],
      }),
    )
    expect(inlineChannelPlugin.config.inspectAccount?.(cfg, "default")).toEqual(
      expect.objectContaining({
        reactionNotifications: "allowlist",
        reactionAllowlist: ["51"],
      }),
    )
    expect(inlineChannelPlugin.config.describeAccount?.(account, cfg)).toEqual(
      expect.objectContaining({
        reactionNotifications: "allowlist",
        reactionAllowlist: ["51"],
      }),
    )

    const snapshot = inlineChannelPlugin.status?.buildAccountSnapshot?.({
      cfg,
      account,
      runtime: { running: false } as any,
    } as any)
    expect(snapshot).toEqual(
      expect.objectContaining({
        reactionNotifications: "allowlist",
        reactionAllowlist: ["51"],
      }),
    )
  })

  it("doctor warnings match Inline group route semantics", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")
    const doctor = inlineChannelPlugin.doctor

    expect(doctor?.shouldSkipDefaultEmptyGroupAllowlistWarning?.({
      account: { groupPolicy: "allowlist" },
      channelName: "inline",
      prefix: "channels.inline",
    })).toBe(true)
    expect(doctor?.collectEmptyAllowlistExtraWarnings?.({
      account: { groupPolicy: "allowlist" },
      channelName: "inline",
      prefix: "channels.inline",
    })).toEqual([
      '- channels.inline: Inline groupPolicy is "allowlist", but no group chats or group sender ids are configured. Group messages stay blocked until you add allowed chats under channels.inline.groups, sender IDs under channels.inline.groupAllowFrom or channels.inline.groups.<chat>.allowFrom, or set channels.inline.groupPolicy to "open" for broad group access.',
    ])
    expect(doctor?.collectEmptyAllowlistExtraWarnings?.({
      account: { groupPolicy: "allowlist", groups: { "123": { requireMention: true } } },
      channelName: "inline",
      prefix: "channels.inline",
    })).toEqual([])
    expect(doctor?.collectEmptyAllowlistExtraWarnings?.({
      account: { groupPolicy: "allowlist", groupAllowFrom: ["123"] },
      channelName: "inline",
      prefix: "channels.inline",
    })).toEqual([])
    expect(doctor?.collectEmptyAllowlistExtraWarnings?.({
      account: { groupPolicy: "allowlist", groups: { "123": { allowFrom: ["456"] } } },
      channelName: "inline",
      prefix: "channels.inline",
    })).toEqual([])
  })

  it("reports Inline group command security audit findings", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")
    const cfg = {
      channels: {
        inline: {
          token: "token",
          groupPolicy: "allowlist",
          allowFrom: ["@alice"],
          groupAllowFrom: ["*"],
          groups: { "88": { requireMention: true } },
        },
      },
    } as OpenClawConfig
    const account = inlineChannelPlugin.config.resolveAccount(cfg, "default")

    const findings = await inlineChannelPlugin.security?.collectAuditFindings?.({
      cfg,
      sourceConfig: cfg,
      account,
      accountId: "default",
      orderedAccountIds: ["default"],
      hasExplicitAccountPath: false,
    } as any)

    expect(findings?.map((finding) => finding.checkId)).toEqual([
      "channels.inline.allowFrom.invalid_entries",
      "channels.inline.groups.allowFrom.wildcard",
    ])
  })

  it("warns when Inline groups have commands but no sender allowlist", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")
    const cfg = {
      commands: { nativeSkills: true },
      channels: {
        inline: {
          token: "token",
          groupPolicy: "allowlist",
          groups: { "chat:88": { requireMention: true } },
        },
      },
    } as OpenClawConfig
    const account = inlineChannelPlugin.config.resolveAccount(cfg, "default")

    const findings = await inlineChannelPlugin.security?.collectAuditFindings?.({
      cfg,
      sourceConfig: cfg,
      account,
      accountId: "default",
      orderedAccountIds: ["default"],
      hasExplicitAccountPath: false,
    } as any)

    expect(findings).toEqual([
      expect.objectContaining({
        checkId: "channels.inline.groups.allowFrom.missing",
        severity: "warn",
        detail: expect.stringContaining("including skill commands"),
      }),
    ])
  })

  it("does not warn when Inline group commands use commands.allowFrom", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")
    const cfg = {
      commands: {
        nativeSkills: true,
        allowFrom: { inline: ["51"] },
      },
      channels: {
        inline: {
          token: "token",
          groupPolicy: "allowlist",
          groups: { "chat:88": { requireMention: true } },
        },
      },
    } as OpenClawConfig
    const account = inlineChannelPlugin.config.resolveAccount(cfg, "default")

    const findings = await inlineChannelPlugin.security?.collectAuditFindings?.({
      cfg,
      sourceConfig: cfg,
      account,
      accountId: "default",
      orderedAccountIds: ["default"],
      hasExplicitAccountPath: false,
    } as any)

    expect(findings).toEqual([])
  })

  it("does not warn when Inline group commands use per-group allowFrom", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")
    const cfg = {
      commands: {
        nativeSkills: true,
      },
      channels: {
        inline: {
          token: "token",
          groupPolicy: "allowlist",
          groups: { "chat:88": { requireMention: true, allowFrom: ["51"] } },
        },
      },
    } as OpenClawConfig
    const account = inlineChannelPlugin.config.resolveAccount(cfg, "default")

    const findings = await inlineChannelPlugin.security?.collectAuditFindings?.({
      cfg,
      sourceConfig: cfg,
      account,
      accountId: "default",
      orderedAccountIds: ["default"],
      hasExplicitAccountPath: false,
    } as any)

    expect(findings).toEqual([])
  })

  it("does not treat Inline access group allowlists as invalid sender entries", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")
    const cfg = {
      accessGroups: {
        operators: {
          type: "message.senders",
          members: { inline: ["51"] },
        },
      },
      channels: {
        inline: {
          token: "token",
          groupPolicy: "allowlist",
          allowFrom: [51, "accessGroup:operators"],
          groupAllowFrom: [51, "accessGroup:operators"],
          groups: { "chat:88": { allowFrom: [51, "accessGroup:operators"] } },
          reactionNotifications: "allowlist",
          reactionAllowlist: [51, "accessGroup:operators"],
        },
      },
    } as OpenClawConfig
    const account = inlineChannelPlugin.config.resolveAccount(cfg, "default")

    const findings = await inlineChannelPlugin.security?.collectAuditFindings?.({
      cfg,
      sourceConfig: cfg,
      account,
      accountId: "default",
      orderedAccountIds: ["default"],
      hasExplicitAccountPath: false,
    } as any)

    expect(findings).toEqual([])
  })

  it("reports invalid Inline reaction allowlist entries", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")
    const cfg = {
      channels: {
        inline: {
          token: "token",
          reactionNotifications: "allowlist",
          reactionAllowlist: ["@alice", "user:51", "accessGroup:operators"],
        },
      },
    } as OpenClawConfig
    const account = inlineChannelPlugin.config.resolveAccount(cfg, "default")

    const findings = await inlineChannelPlugin.security?.collectAuditFindings?.({
      cfg,
      sourceConfig: cfg,
      account,
      accountId: "default",
      orderedAccountIds: ["default"],
      hasExplicitAccountPath: false,
    } as any)

    expect(findings).toEqual([
      expect.objectContaining({
        checkId: "channels.inline.reactionAllowlist.invalid_entries",
        severity: "warn",
        detail: expect.stringContaining("@alice"),
      }),
    ])
  })

  it("flags disabled access groups for reachable Inline groups", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")
    const cfg = {
      commands: { useAccessGroups: false },
      channels: {
        inline: {
          token: "token",
          groupPolicy: "allowlist",
          groupAllowFrom: ["51"],
        },
      },
    } as OpenClawConfig
    const account = inlineChannelPlugin.config.resolveAccount(cfg, "default")

    const findings = await inlineChannelPlugin.security?.collectAuditFindings?.({
      cfg,
      sourceConfig: cfg,
      account,
      accountId: "default",
      orderedAccountIds: ["default"],
      hasExplicitAccountPath: false,
    } as any)

    expect(findings).toEqual([
      expect.objectContaining({
        checkId: "channels.inline.groups.commands.access_groups_disabled",
        severity: "critical",
      }),
    ])
  })

  it("setup wizard resolves configured state from inline token config", async () => {
    vi.resetModules()
    const { inlineSetupWizard } = await import("./setup-surface")

    const configured = await inlineSetupWizard.status.resolveConfigured({
      cfg: {
        channels: {
          inline: {
            token: "token",
          },
        },
      } as OpenClawConfig,
    })
    const unconfigured = await inlineSetupWizard.status.resolveConfigured({
      cfg: {
        channels: {
          inline: {},
        },
      } as OpenClawConfig,
    })

    expect(configured).toBe(true)
    expect(unconfigured).toBe(false)
    expect(inlineSetupWizard.status.unconfiguredLabel).toBe("needs bot token")
    expect(inlineSetupWizard.allowFrom?.parseId("user:123")).toBe("123")
    expect(inlineSetupWizard.allowFrom?.parseId("inline:user:123")).toBe("123")
    expect(inlineSetupWizard.allowFrom?.parseId("inline:chat:123")).toBeNull()
    expect(inlineSetupWizard.allowFrom?.parseId("inline:0")).toBeNull()
    expect(inlineSetupWizard.dmPolicy).toBeDefined()

    const patched = await inlineSetupWizard.allowFrom?.apply({
      cfg: {
        channels: {
          inline: {
            token: "token",
          },
        },
      } as OpenClawConfig,
      accountId: "default",
      allowFrom: ["123"],
    })
    expect(patched).toBeDefined()
    const patchedInline = (patched as OpenClawConfig).channels?.inline as {
      dmPolicy?: string
      allowFrom?: string[]
    }
    expect(patchedInline.dmPolicy).toBe("allowlist")
    expect(patchedInline.allowFrom).toEqual(["123"])

    const prepared = await inlineSetupWizard.prepare?.({
      cfg: {
        channels: {
          inline: {
            token: "token",
          },
        },
      } as OpenClawConfig,
      accountId: "default",
      credentialValues: {},
      runtime: {} as any,
      prompter: {} as any,
    })
    expect(prepared?.cfg?.channels?.inline?.groups?.["*"]?.requireMention).toBe(true)

    expect(inlineSetupWizard.groupAccess?.currentPolicy({
      cfg: {
        channels: {
          inline: {
            token: "token",
          },
        },
      } as OpenClawConfig,
      accountId: "default",
    })).toBe("allowlist")
    expect(inlineSetupWizard.groupAccess?.helpLines?.join("\n")).toContain(
      "Use /whoami in a group",
    )
    expect(inlineSetupWizard.groupAccess?.helpLines?.join("\n")).not.toContain("/chatinfo")

    const resolvedGroups = await inlineSetupWizard.groupAccess?.resolveAllowlist?.({
      cfg: {} as OpenClawConfig,
      accountId: "default",
      credentialValues: {},
      entries: ["chat:88", "*", "bad"],
      prompter: { note: vi.fn() },
    })
    expect(resolvedGroups).toEqual([
      expect.objectContaining({ input: "chat:88", resolved: true, id: "88" }),
      expect.objectContaining({ input: "*", resolved: true, id: "*" }),
      expect.objectContaining({ input: "bad", resolved: false, id: null }),
    ])

    const patchedGroups = inlineSetupWizard.groupAccess?.applyAllowlist?.({
      cfg: {
        channels: {
          inline: {
            token: "token",
            groups: {
              "88": {
                requireMention: false,
                systemPrompt: "existing",
              },
            },
          },
        },
      } as OpenClawConfig,
      accountId: "default",
      resolved: resolvedGroups,
    })
    expect(patchedGroups?.channels?.inline?.groupPolicy).toBe("allowlist")
    expect(patchedGroups?.channels?.inline?.groups?.["88"]?.requireMention).toBe(false)
    expect(patchedGroups?.channels?.inline?.groups?.["88"]?.systemPrompt).toBe("existing")
    expect(patchedGroups?.channels?.inline?.groups?.["*"]?.requireMention).toBe(true)
  })

  it.runIf(process.platform !== "win32")("setup wizard rejects unavailable token files", async () => {
    vi.resetModules()
    const { inlineSetupWizard } = await import("./setup-surface")
    const dir = await mkdtemp(path.join(os.tmpdir(), "inline-setup-token-"))
    const tokenPath = path.join(dir, "token.txt")
    const linkPath = path.join(dir, "token-link.txt")
    await writeFile(tokenPath, "file-token\n", "utf8")
    await symlink(tokenPath, linkPath)

    const cfg = {
      channels: {
        inline: {
          tokenFile: linkPath,
        },
      },
    } as OpenClawConfig

    expect(await inlineSetupWizard.status.resolveConfigured({ cfg })).toBe(false)
    expect(await inlineSetupWizard.status.resolveConfigured({ cfg, accountId: "default" })).toBe(
      false,
    )
  })

  it("setup wizard treats INLINE_BOT_TOKEN as an env-token alias", async () => {
    const previousToken = process.env.INLINE_TOKEN
    const previousBotToken = process.env.INLINE_BOT_TOKEN
    try {
      delete process.env.INLINE_TOKEN
      process.env.INLINE_BOT_TOKEN = "bot-token"
      vi.resetModules()
      const { inlineSetupWizard } = await import("./setup-surface")

      expect(
        await inlineSetupWizard.status.resolveConfigured({
          cfg: {
            channels: {
              inline: {
                enabled: true,
              },
            },
          } as OpenClawConfig,
        }),
      ).toBe(true)

      expect(inlineSetupWizard.credentials[0]?.inspect({
        cfg: {
          channels: {
            inline: {
              enabled: true,
            },
          },
        } as OpenClawConfig,
        accountId: "default",
      })).toEqual(
        expect.objectContaining({
          accountConfigured: true,
          envValue: "bot-token",
          resolvedValue: "bot-token",
        }),
      )
    } finally {
      if (previousToken === undefined) {
        delete process.env.INLINE_TOKEN
      } else {
        process.env.INLINE_TOKEN = previousToken
      }
      if (previousBotToken === undefined) {
        delete process.env.INLINE_BOT_TOKEN
      } else {
        process.env.INLINE_BOT_TOKEN = previousBotToken
      }
    }
  })

  it("describes reply-thread action semantics based on replyThreads config", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")

    const disabledHints =
      inlineChannelPlugin.agentPrompt?.messageToolHints?.({
        cfg: {
          channels: {
            inline: {
              token: "token",
              capabilities: { replyThreads: false },
            },
          },
        } as OpenClawConfig,
        accountId: "default",
      } as any) ?? []

    expect(disabledHints.join("\n")).toContain("reply threads are disabled")
    expect(disabledHints.join("\n")).toContain("legacy reply path")
    expect(disabledHints.join("\n")).toContain("not a dedicated Inline reply-thread chat")
    expect(disabledHints.join("\n")).toContain("attachmentUrls")

    const enabledHints =
      inlineChannelPlugin.agentPrompt?.messageToolHints?.({
        cfg: {
          channels: {
            inline: {
              token: "token",
              capabilities: { replyThreads: true },
            },
          },
        } as OpenClawConfig,
        accountId: "default",
      } as any) ?? []

    expect(enabledHints.join("\n").toLowerCase()).toContain("reply thread")
    expect(enabledHints.join("\n")).toContain("thread-create")
    expect(enabledHints.join("\n")).toContain("current message")
    expect(enabledHints.join("\n")).toContain("attachmentUrls")
  })

  it("keeps gateway startAccount pending until monitor completion", async () => {
    vi.resetModules()

    const stop = vi.fn(async () => {})
    let resolveDone: (() => void) | null = null
    const done = new Promise<void>((resolve) => {
      resolveDone = resolve
    })
    const monitorInlineProvider = vi.fn(async () => ({ stop, done }))
    vi.doMock("./monitor", () => ({
      monitorInlineProvider,
    }))

    const { inlineChannelPlugin } = await import("./channel")

    const abortController = new AbortController()
    const channelRuntime = {
      runtimeContexts: {
        register: vi.fn(),
        get: vi.fn(),
        watch: vi.fn(),
      },
    }
    let status = {
      accountId: "default",
      running: false,
      connected: false,
      configured: true,
      lastStartAt: null as number | null,
      lastStopAt: null as number | null,
      lastConnectedAt: null as number | null,
      lastEventAt: null as number | null,
      lastTransportActivityAt: null as number | null,
      lastError: null as string | null,
    }
    const startPromise = inlineChannelPlugin.gateway?.startAccount?.({
      cfg: {
        channels: {
          inline: {
            token: "token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } satisfies OpenClawConfig,
      account: {
        accountId: "default",
        name: "Default",
        enabled: true,
        configured: true,
        baseUrl: "https://api.inline.chat",
        token: "token",
        tokenFile: null,
        config: {},
      },
      runtime: {} as any,
      channelRuntime,
      abortSignal: abortController.signal,
      log: {
        info: vi.fn(),
        warn: vi.fn(),
        error: vi.fn(),
      },
      getStatus: () => status,
      setStatus: (next) => {
        status = {
          ...status,
          ...next,
        }
      },
    } as any)

    let settled = false
    void startPromise?.then(() => {
      settled = true
    })
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(settled).toBe(false)
    expect(monitorInlineProvider).toHaveBeenCalledWith(
      expect.objectContaining({
        channelRuntime,
      }),
    )
    expect(status.connected).toBe(false)
    expect(status.lastConnectedAt).toBeNull()
    expect(status.lastTransportActivityAt).toBeNull()

    resolveDone?.()
    await startPromise

    expect(stop).toHaveBeenCalled()
  })

  it("clears SDK cursor state when credentials change or account is removed", async () => {
    vi.resetModules()
    const stateDir = await mkdtemp(path.join(os.tmpdir(), "inline-state-"))
    await setInlineTestRuntime({ stateDir })
    const { inlineChannelPlugin } = await import("./channel")

    const statePath = path.join(stateDir, "channels", "inline", "default.json")
    await mkdir(path.dirname(statePath), { recursive: true })

    await writeFile(statePath, "{}", "utf8")
    await inlineChannelPlugin.lifecycle?.onAccountConfigChanged?.({
      accountId: "default",
      prevCfg: {
        channels: {
          inline: {
            token: "old-token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } as OpenClawConfig,
      nextCfg: {
        channels: {
          inline: {
            token: "new-token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } as OpenClawConfig,
      runtime: {} as any,
    })
    await expect(access(statePath)).rejects.toMatchObject({ code: "ENOENT" })

    await writeFile(statePath, "{}", "utf8")
    const sameCfg = {
      channels: {
        inline: {
          token: "new-token",
          baseUrl: "https://api.inline.chat",
        },
      },
    } as OpenClawConfig
    await inlineChannelPlugin.lifecycle?.onAccountConfigChanged?.({
      accountId: "default",
      prevCfg: sameCfg,
      nextCfg: sameCfg,
      runtime: {} as any,
    })
    await expect(access(statePath)).resolves.toBeUndefined()

    await inlineChannelPlugin.lifecycle?.onAccountRemoved?.({
      accountId: "default",
      prevCfg: sameCfg,
      runtime: {} as any,
    })
    await expect(access(statePath)).rejects.toMatchObject({ code: "ENOENT" })
  })

  it("gateway logoutAccount clears configured credentials", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")

    const result = await inlineChannelPlugin.gateway?.logoutAccount?.({
      accountId: "default",
      cfg: {
        channels: {
          inline: {
            token: "token-default",
            tokenFile: "/tmp/default-token",
            accounts: {
              ops: {
                token: "token-ops",
                tokenFile: "/tmp/ops-token",
              },
            },
          },
        },
      } as OpenClawConfig,
      account: {
        accountId: "default",
      } as any,
      runtime: {} as any,
      log: {
        info: vi.fn(),
        warn: vi.fn(),
        error: vi.fn(),
      },
    } as any)

    const nextCfg = result?.cfg as OpenClawConfig
    const inlineCfg = (nextCfg.channels?.inline ?? {}) as {
      token?: string
      tokenFile?: string
      accounts?: Record<string, { token?: string; tokenFile?: string }>
    }

    expect(result?.cleared).toBe(true)
    expect(inlineCfg.token).toBeUndefined()
    expect(inlineCfg.tokenFile).toBeUndefined()
    expect(inlineCfg.accounts?.ops?.token).toBe("token-ops")
    expect(inlineCfg.accounts?.ops?.tokenFile).toBe("/tmp/ops-token")
  })

  it("gateway logoutAccount reports SecretRef credentials as cleared", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")

    const result = await inlineChannelPlugin.gateway?.logoutAccount?.({
      accountId: "default",
      cfg: {
        channels: {
          inline: {
            token: { source: "file", provider: "default", id: "inline/default" },
          },
        },
      } as OpenClawConfig,
      account: {
        accountId: "default",
      } as any,
      runtime: {} as any,
      log: {
        info: vi.fn(),
        warn: vi.fn(),
        error: vi.fn(),
      },
    } as any)

    const nextInline = result?.cfg?.channels?.inline as { token?: unknown } | undefined

    expect(result?.cleared).toBe(true)
    expect(result?.loggedOut).toBe(true)
    expect(nextInline?.token).toBeUndefined()
  })

  it("collects status issues for unconfigured and runtime failures", async () => {
    vi.resetModules()
    const { collectInlineStatusIssues } = await import("./status-issues")

    const issues = collectInlineStatusIssues([
      {
        accountId: "default",
        enabled: true,
        configured: false,
        tokenSource: "config",
      },
      {
        accountId: "ops",
        enabled: true,
        configured: true,
        baseUrl: "[missing]",
        lastError: "401 unauthorized",
        probe: {
          ok: false,
          error: "request failed: 401",
        },
      },
    ])

    expect(
      issues.some(
        (issue) =>
          issue.accountId === "default" &&
          issue.kind === "config" &&
          issue.message.includes("configured but unavailable"),
      ),
    ).toBe(true)
    expect(issues.some((issue) => issue.accountId === "ops" && issue.kind === "config")).toBe(
      true,
    )
    expect(issues.some((issue) => issue.accountId === "ops" && issue.kind === "auth")).toBe(true)
  })

  it("collects recent reconnect-loop diagnostics as runtime issues", async () => {
    vi.resetModules()
    const { collectInlineStatusIssues } = await import("./status-issues")

    const issues = collectInlineStatusIssues([
      {
        accountId: "default",
        enabled: true,
        configured: true,
        running: true,
        connected: false,
        lastStartAt: Date.now() - 121_000,
        diagnostics: {
          protocol: {
            lastFailureAt: Date.now(),
            lastFailureReason: "authentication timeout after 10000ms",
            transport: {
              reconnectCount: 5,
              lastReconnectCause: "ping-timeout",
            },
            ping: {
              lastTimeoutAt: Date.now(),
            },
          },
        },
      },
    ])

    expect(issues.some((issue) => issue.message.includes("flapping"))).toBe(true)
    expect(issues.some((issue) => issue.message.includes("ping watchdog"))).toBe(true)
    expect(issues.some((issue) => issue.message.includes("running but not connected"))).toBe(true)
  })

  it("does not flag Inline connecting state during startup grace", async () => {
    vi.resetModules()
    const { collectInlineStatusIssues } = await import("./status-issues")

    const issues = collectInlineStatusIssues([
      {
        accountId: "default",
        enabled: true,
        configured: true,
        running: true,
        connected: false,
        lastStartAt: Date.now(),
      },
    ])

    expect(issues.some((issue) => issue.message.includes("running but not connected"))).toBe(false)
  })

  it("status includes lastProbeAt in channel summary and account snapshots", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")

    const channelSummary = inlineChannelPlugin.status?.buildChannelSummary?.({
      account: {} as any,
      cfg: {} as OpenClawConfig,
      defaultAccountId: "default",
      snapshot: {
        configured: true,
        running: true,
        lastStartAt: 100,
        lastStopAt: null,
        lastError: null,
        lastProbeAt: 222,
      } as any,
    } as any)

    expect(channelSummary).toEqual(
      expect.objectContaining({
        configured: true,
        running: true,
        lastStartAt: 100,
        lastProbeAt: 222,
      }),
    )

    const accountSnapshot = inlineChannelPlugin.status?.buildAccountSnapshot?.({
      cfg: {} as OpenClawConfig,
      account: {
        accountId: "default",
        name: "Default",
        enabled: true,
        configured: true,
        baseUrl: "https://api.inline.chat",
        token: "token",
        tokenFile: null,
      } as any,
      runtime: {
        running: true,
        connected: true,
        lastStartAt: 333,
        lastStopAt: null,
        lastConnectedAt: 334,
        lastEventAt: 335,
        lastTransportActivityAt: 336,
        lastError: null,
        lastInboundAt: null,
        lastOutboundAt: null,
        lastProbeAt: 444,
        diagnostics: { protocol: { state: "open" } },
      } as any,
      probe: {
        ok: true,
      },
    } as any)

    expect(accountSnapshot).toEqual(
      expect.objectContaining({
        lastStartAt: 333,
        connected: true,
        lastConnectedAt: 334,
        lastEventAt: 335,
        lastTransportActivityAt: 336,
        lastProbeAt: 444,
        diagnostics: { protocol: { state: "open" } },
        probe: { ok: true },
      }),
    )
  })

  it("resolves group mention + tool policy from channels.inline.groups", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")

    const cfg = {
      channels: {
        inline: {
          requireMention: true,
          groups: {
            "chat:88": {
              requireMention: false,
              tools: { allow: ["message"] },
            },
          },
        },
      },
    } satisfies OpenClawConfig

    const requireMention = inlineChannelPlugin.groups?.resolveRequireMention?.({
      cfg,
      accountId: "default",
      groupId: "88",
    } as any)
    const tools = inlineChannelPlugin.groups?.resolveToolPolicy?.({
      cfg,
      accountId: "default",
      groupId: "88",
      senderId: "42",
    } as any)

    expect(requireMention).toBe(false)
    expect(tools).toEqual({ allow: ["message"] })
  })

  it("defaults group requireMention to false when unset", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")

    const requireMention = inlineChannelPlugin.groups?.resolveRequireMention?.({
      cfg: {
        channels: {
          inline: {},
        },
      } as OpenClawConfig,
      accountId: "default",
      groupId: "88",
    } as any)

    expect(requireMention).toBe(false)
  })

  it("exposes inline rpc-backed message actions", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")

    const actions = inlineChannelPlugin.actions?.listActions?.({
      cfg: {
        channels: {
          inline: {
            token: "token",
          },
        },
      } as OpenClawConfig,
    }) ?? []

    expect(actions).toContain("read")
    expect(actions).toContain("send")
    expect(actions).toContain("sendAttachment")
    expect(actions).toContain("reply")
    expect(actions).toContain("thread-reply")
    expect(actions).toContain("react")
    expect(actions).toContain("reactions")
    expect(actions).toContain("edit")
    expect(actions).toContain("channel-edit")
    expect(actions).toContain("renameGroup")
    expect(actions).toContain("addParticipant")
    expect(actions).toContain("kick")
  })

  it("outbound sendText uses the Inline SDK client (mocked)", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const sendMessage = vi.fn(async () => ({ messageId: null }))
    const close = vi.fn(async () => {})

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        sendMessage = sendMessage
        close = close
      },
    })

    // The channel plugin uses getInlineRuntime() for state dir + chunker.
    await setInlineTestRuntime()

    const { inlineChannelPlugin } = await import("./channel")

    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
          parseMarkdown: true,
        },
      },
    } satisfies OpenClawConfig

    await inlineChannelPlugin.outbound.sendText?.({
      cfg,
      to: "chat:7",
      text: "hi",
      accountId: "default",
    } as any)

    expect(connect).toHaveBeenCalled()
    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({ chatId: 7n, text: "hi", parseMarkdown: true }),
    )
    expect(close).toHaveBeenCalled()
  })

  it("outbound sendText suppresses copied OpenClaw runtime context", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const sendMessage = vi.fn(async () => ({ messageId: null }))
    const close = vi.fn(async () => {})

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        sendMessage = sendMessage
        close = close
      },
    })

    await setInlineTestRuntime()

    const { inlineChannelPlugin } = await import("./channel")

    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
        },
      },
    } satisfies OpenClawConfig

    const result = await inlineChannelPlugin.outbound.sendText?.({
      cfg,
      to: "chat:7",
      text: [
        "OpenClaw runtime context for the immediately preceding user message.",
        "This context is runtime-generated, not user-authored. Keep internal details private.",
        "",
        "Read HEARTBEAT.md if it exists. If nothing needs attention, reply HEARTBEAT_OK.",
      ].join("\n"),
      accountId: "default",
    } as any)

    expect(result).toMatchObject({ channel: "inline", messageId: "", chatId: "7" })
    expect(connect).not.toHaveBeenCalled()
    expect(sendMessage).not.toHaveBeenCalled()
    expect(close).not.toHaveBeenCalled()
  })

  it("outbound sendText supports explicit user targets", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const sendMessage = vi.fn(async () => ({ messageId: null }))
    const close = vi.fn(async () => {})

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        sendMessage = sendMessage
        close = close
      },
    })

    await setInlineTestRuntime({
      loadWebMedia: vi.fn(async () => ({
        buffer: Buffer.from([1, 2, 3]),
        contentType: "image/png",
        kind: "image",
        fileName: "image.png",
      })),
      detectMime: vi.fn(async () => "image/png"),
    })

    const { inlineChannelPlugin } = await import("./channel")

    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
          parseMarkdown: true,
        },
      },
    } satisfies OpenClawConfig

    const result = await inlineChannelPlugin.outbound.sendText?.({
      cfg,
      to: "user:42",
      text: "hi",
      accountId: "default",
    } as any)

    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({ userId: 42n, text: "hi", parseMarkdown: true }),
    )
    expect(sendMessage).not.toHaveBeenCalledWith(
      expect.objectContaining({ chatId: 42n }),
    )
    expect(result).toEqual(expect.objectContaining({ chatId: "user:42" }))
    expect(close).toHaveBeenCalled()
  })

  it("outbound sendText disambiguates bare numeric targets to user ids when needed", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const invokeRaw = vi.fn(async () => ({
      oneofKind: "getChats",
      getChats: {
        chats: [{ id: 7n, title: "general" }],
        users: [{ id: 1600n, firstName: "Mo" }],
        dialogs: [],
      },
    }))
    const sendMessage = vi.fn(async () => ({ messageId: null }))
    const close = vi.fn(async () => {})

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        invokeRaw = invokeRaw
        sendMessage = sendMessage
        close = close
      },
    })

    await setInlineTestRuntime({
      loadWebMedia: vi.fn(async () => ({
        buffer: Buffer.from([1, 2, 3]),
        contentType: undefined,
        kind: "image",
        fileName: undefined,
      })),
      detectMime: vi.fn(async () => undefined),
    })

    const { inlineChannelPlugin } = await import("./channel")
    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
          parseMarkdown: true,
        },
      },
    } satisfies OpenClawConfig

    const result = await inlineChannelPlugin.outbound.sendText?.({
      cfg,
      to: "1600",
      text: "hi",
      accountId: "default",
    } as any)

    expect(invokeRaw).toHaveBeenCalled()
    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({ userId: 1600n, text: "hi", parseMarkdown: true }),
    )
    expect(sendMessage).not.toHaveBeenCalledWith(
      expect.objectContaining({ chatId: 1600n }),
    )
    expect(result).toEqual(expect.objectContaining({ chatId: "user:1600" }))
    expect(close).toHaveBeenCalled()
  })

  it("outbound sendText treats inline:<id> targets as explicit chat ids", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const invokeRaw = vi.fn(async () => ({
      oneofKind: "getChats",
      getChats: { chats: [], users: [], dialogs: [] },
    }))
    const sendMessage = vi.fn(async () => ({ messageId: null }))
    const close = vi.fn(async () => {})

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        invokeRaw = invokeRaw
        sendMessage = sendMessage
        close = close
      },
    })

    await setInlineTestRuntime()

    const { inlineChannelPlugin } = await import("./channel")
    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
          parseMarkdown: true,
        },
      },
    } satisfies OpenClawConfig

    await inlineChannelPlugin.outbound.sendText?.({
      cfg,
      to: "inline:1600",
      text: "hi",
      accountId: "default",
    } as any)

    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({ chatId: 1600n, text: "hi", parseMarkdown: true }),
    )
    expect(invokeRaw).not.toHaveBeenCalled()
    expect(close).toHaveBeenCalled()
  })

  it("outbound sendText rejects ambiguous bare numeric targets", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const invokeRaw = vi.fn(async () => ({
      oneofKind: "getChats",
      getChats: {
        chats: [{ id: 1600n, title: "project" }],
        users: [{ id: 1600n, firstName: "Mo" }],
        dialogs: [],
      },
    }))
    const sendMessage = vi.fn(async () => ({ messageId: null }))
    const close = vi.fn(async () => {})

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        invokeRaw = invokeRaw
        sendMessage = sendMessage
        close = close
      },
    })

    await setInlineTestRuntime({
      loadWebMedia: vi.fn(async () => ({
        buffer: Buffer.from([1, 2, 3]),
        contentType: "image/png",
        kind: "image",
        fileName: "image.png",
      })),
      detectMime: vi.fn(async () => "image/png"),
    })

    const { inlineChannelPlugin } = await import("./channel")
    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
        },
      },
    } satisfies OpenClawConfig

    await expect(
      inlineChannelPlugin.outbound.sendText?.({
        cfg,
        to: "1600",
        text: "hi",
        accountId: "default",
      } as any),
    ).rejects.toThrow(/ambiguous numeric target/)
    expect(sendMessage).not.toHaveBeenCalled()
    expect(close).toHaveBeenCalled()
  })

  it("outbound sendText surfaces a clear hint for chat/user target mixups", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const invokeRaw = vi.fn(async () => ({
      oneofKind: "getChats",
      getChats: {
        chats: [],
        users: [],
        dialogs: [],
      },
    }))
    const sendMessage = vi.fn(async () => {
      throw new Error(
        "sendMessage: request failed (CHAT_INVALID; target=chat:1600; media=none; textLen=2; replyTo=none)",
      )
    })
    const close = vi.fn(async () => {})

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        invokeRaw = invokeRaw
        sendMessage = sendMessage
        close = close
      },
    })

    await setInlineTestRuntime()

    const { inlineChannelPlugin } = await import("./channel")
    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
          parseMarkdown: true,
        },
      },
    } satisfies OpenClawConfig

    await expect(
      inlineChannelPlugin.outbound.sendText?.({
        cfg,
        to: "1600",
        text: "hi",
        accountId: "default",
      } as any),
    ).rejects.toThrow(/If this is a user id, use user:1600/)
    expect(sendMessage).toHaveBeenCalled()
    expect(close).toHaveBeenCalled()
  })

  it("outbound uses replyToId (not threadId) for Inline replyToMsgId", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const sendMessage = vi.fn(async () => ({ messageId: null }))
    const close = vi.fn(async () => {})

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        sendMessage = sendMessage
        close = close
      },
    })

    await setInlineTestRuntime({
      loadWebMedia: vi.fn(async () => ({
        buffer: Buffer.from([1, 2, 3]),
        contentType: "image/png",
        kind: "image",
        fileName: "image.png",
      })),
      detectMime: vi.fn(async () => "image/png"),
    })

    const { inlineChannelPlugin } = await import("./channel")

    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
          parseMarkdown: true,
        },
      },
    } satisfies OpenClawConfig

    await inlineChannelPlugin.outbound.sendText?.({
      cfg,
      to: "chat:7",
      text: "hi",
      accountId: "default",
      threadId: "42",
    } as any)

    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({ chatId: 7n, text: "hi" }),
    )
    expect(sendMessage).not.toHaveBeenCalledWith(
      expect.objectContaining({ replyToMsgId: 42n }),
    )

    await inlineChannelPlugin.outbound.sendText?.({
      cfg,
      to: "chat:7",
      text: "hi",
      accountId: "default",
      replyToId: "99",
      threadId: "42",
    } as any)

    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({ chatId: 7n, text: "hi", replyToMsgId: 99n }),
    )

    expect(connect).toHaveBeenCalled()
    expect(close).toHaveBeenCalled()
  })

  it("outbound sendText routes into the child reply-thread chat when replyThreads is enabled", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const sendMessage = vi.fn(async () => ({ messageId: null }))
    const close = vi.fn(async () => {})

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        sendMessage = sendMessage
        close = close
      },
    })

    await setInlineTestRuntime()

    const { inlineChannelPlugin } = await import("./channel")

    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
          capabilities: {
            replyThreads: true,
          },
        },
      },
    } satisfies OpenClawConfig

    await inlineChannelPlugin.outbound.sendText?.({
      cfg,
      to: "chat:7",
      text: "hi",
      accountId: "default",
      threadId: "42",
    } as any)

    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({ chatId: 42n, text: "hi" }),
    )
    expect(connect).toHaveBeenCalled()
    expect(close).toHaveBeenCalled()
  })

  it("outbound sendMedia uploads and sends Inline media", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const uploadFile = vi.fn(async () => ({ fileUniqueId: "INP_1", photoId: 101n }))
    const sendMessage = vi.fn(async () => ({ messageId: 55n }))
    const close = vi.fn(async () => {})
    const loadWebMedia = vi.fn(async () => ({
      buffer: Buffer.from([1, 2, 3]),
      contentType: "image/png",
      kind: "image",
      fileName: "image.png",
    }))

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        uploadFile = uploadFile
        sendMessage = sendMessage
        close = close
      },
    })

    mockOpenClawMediaSdk({
      loadWebMedia,
      detectMime: vi.fn(async () => "image/png"),
    })

    await setInlineTestRuntime({
      loadWebMedia,
      detectMime: vi.fn(async () => "image/png"),
    })

    const { inlineChannelPlugin } = await import("./channel")

    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
          parseMarkdown: true,
        },
      },
    } satisfies OpenClawConfig

    await inlineChannelPlugin.outbound.sendMedia?.({
      cfg,
      to: "chat:7",
      text: "caption",
      mediaUrl: "https://example.com/image.png",
      accountId: "default",
      replyToId: "9",
    } as any)

    expect(uploadFile).toHaveBeenCalledWith(
      expect.objectContaining({
        type: "photo",
      }),
    )
    expect(loadWebMedia).toHaveBeenCalledWith(
      "https://example.com/image.png",
      300 * 1024 * 1024,
    )
    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        chatId: 7n,
        text: "caption",
        replyToMsgId: 9n,
        media: {
          kind: "photo",
          photoId: 101n,
        },
        parseMarkdown: true,
      }),
    )
    expect(close).toHaveBeenCalled()
  })

  it("outbound sendMedia strips copied OpenClaw runtime captions", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const uploadFile = vi.fn(async () => ({ fileUniqueId: "INP_1", photoId: 101n }))
    const sendMessage = vi.fn(async () => ({ messageId: 55n }))
    const close = vi.fn(async () => {})
    const loadWebMedia = vi.fn(async () => ({
      buffer: Buffer.from([1, 2, 3]),
      contentType: "image/png",
      kind: "image",
      fileName: "image.png",
    }))

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        uploadFile = uploadFile
        sendMessage = sendMessage
        close = close
      },
    })

    mockOpenClawMediaSdk({
      loadWebMedia,
      detectMime: vi.fn(async () => "image/png"),
    })

    await setInlineTestRuntime({
      loadWebMedia,
      detectMime: vi.fn(async () => "image/png"),
    })

    const { inlineChannelPlugin } = await import("./channel")

    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
          parseMarkdown: true,
        },
      },
    } satisfies OpenClawConfig

    await inlineChannelPlugin.outbound.sendMedia?.({
      cfg,
      to: "chat:7",
      text: [
        "OpenClaw runtime event.",
        "This context is runtime-generated, not user-authored. Keep internal details private.",
        "",
        "Read HEARTBEAT.md if it exists. If nothing needs attention, reply HEARTBEAT_OK.",
      ].join("\n"),
      mediaUrl: "https://example.com/image.png",
      accountId: "default",
    } as any)

    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        chatId: 7n,
        media: {
          kind: "photo",
          photoId: 101n,
        },
      }),
    )
    expect(sendMessage).not.toHaveBeenCalledWith(expect.objectContaining({ text: expect.any(String) }))
  })

  it("outbound sendMedia routes into the child reply-thread chat when replyThreads is enabled", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const uploadFile = vi.fn(async () => ({ fileUniqueId: "INP_1", photoId: 101n }))
    const sendMessage = vi.fn(async () => ({ messageId: 55n }))
    const close = vi.fn(async () => {})
    const loadWebMedia = vi.fn(async () => ({
      buffer: Buffer.from([1, 2, 3]),
      contentType: "image/png",
      kind: "image",
      fileName: "image.png",
    }))

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        uploadFile = uploadFile
        sendMessage = sendMessage
        close = close
      },
    })

    mockOpenClawMediaSdk({
      loadWebMedia,
      detectMime: vi.fn(async () => "image/png"),
    })

    await setInlineTestRuntime({
      loadWebMedia,
      detectMime: vi.fn(async () => "image/png"),
    })

    const { inlineChannelPlugin } = await import("./channel")

    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
          capabilities: {
            replyThreads: true,
          },
          parseMarkdown: true,
        },
      },
    } satisfies OpenClawConfig

    await inlineChannelPlugin.outbound.sendMedia?.({
      cfg,
      to: "chat:7",
      text: "caption",
      mediaUrl: "https://example.com/image.png",
      accountId: "default",
      threadId: "42",
    } as any)

    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        chatId: 42n,
        text: "caption",
      }),
    )
    expect(close).toHaveBeenCalled()
  })

  it("outbound sendMedia supports explicit user targets", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const uploadFile = vi.fn(async () => ({ fileUniqueId: "INP_1", photoId: 101n }))
    const sendMessage = vi.fn(async () => ({ messageId: 55n }))
    const close = vi.fn(async () => {})

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        uploadFile = uploadFile
        sendMessage = sendMessage
        close = close
      },
    })

    mockOpenClawMediaSdk({
      loadWebMedia: vi.fn(async () => ({
        buffer: Buffer.from([1, 2, 3]),
        contentType: "image/png",
        kind: "image",
        fileName: "image.png",
      })),
      detectMime: vi.fn(async () => "image/png"),
    })

    await setInlineTestRuntime({
      loadWebMedia: vi.fn(async () => ({
        buffer: Buffer.from([1, 2, 3]),
        contentType: "image/png",
        kind: "image",
        fileName: "image.png",
      })),
      detectMime: vi.fn(async () => "image/png"),
    })

    const { inlineChannelPlugin } = await import("./channel")

    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
          parseMarkdown: true,
        },
      },
    } satisfies OpenClawConfig

    await inlineChannelPlugin.outbound.sendMedia?.({
      cfg,
      to: "inline:user:42",
      text: "caption",
      mediaUrl: "https://example.com/image.png",
      accountId: "default",
      replyToId: "9",
    } as any)

    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        userId: 42n,
        text: "caption",
        replyToMsgId: 9n,
      }),
    )
    expect(sendMessage).not.toHaveBeenCalledWith(
      expect.objectContaining({ chatId: 42n }),
    )
    expect(close).toHaveBeenCalled()
  })

  it("outbound sendMedia falls back to loadWebMedia kind when mime/ext are missing", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const uploadFile = vi.fn(async () => ({ fileUniqueId: "INP_1", photoId: 101n }))
    const sendMessage = vi.fn(async () => ({ messageId: 55n }))
    const close = vi.fn(async () => {})

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        uploadFile = uploadFile
        sendMessage = sendMessage
        close = close
      },
    })

    mockOpenClawMediaSdk({
      loadWebMedia: vi.fn(async () => ({
        buffer: Buffer.from([1, 2, 3]),
        contentType: undefined,
        kind: "image",
        fileName: undefined,
      })),
      detectMime: vi.fn(async () => undefined),
    })

    await setInlineTestRuntime({
      loadWebMedia: vi.fn(async () => ({
        buffer: Buffer.from([1, 2, 3]),
        contentType: "image/png",
        kind: "image",
        fileName: "image.png",
      })),
      detectMime: vi.fn(async () => "image/png"),
    })

    const { inlineChannelPlugin } = await import("./channel")

    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
        },
      },
    } satisfies OpenClawConfig

    await inlineChannelPlugin.outbound.sendMedia?.({
      cfg,
      to: "chat:7",
      text: "caption",
      mediaUrl: "https://example.com/no-meta",
      accountId: "default",
    } as any)

    expect(uploadFile).toHaveBeenCalledWith(
      expect.objectContaining({
        type: "photo",
      }),
    )
    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        chatId: 7n,
        media: {
          kind: "photo",
          photoId: 101n,
        },
      }),
    )
    expect(close).toHaveBeenCalled()
  })

  it("outbound sendMedia does not bypass blocked local media paths", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const uploadFile = vi.fn(async () => ({ fileUniqueId: "INP_1", photoId: 101n }))
    const sendMessage = vi.fn(async () => ({ messageId: 55n }))
    const close = vi.fn(async () => {})
    const loadWebMedia = vi.fn(async () => {
      throw new Error("Local media path is not under an allowed directory: /tmp/latest-download.jpeg")
    })

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        uploadFile = uploadFile
        sendMessage = sendMessage
        close = close
      },
    })

    mockOpenClawMediaSdk({
      loadWebMedia,
      detectMime: vi.fn(async () => "image/jpeg"),
    })

    await setInlineTestRuntime({
      loadWebMedia,
      detectMime: vi.fn(async () => "image/jpeg"),
    })

    const { inlineChannelPlugin } = await import("./channel")

    const mediaPath = path.join(os.homedir(), ".openclaw", "workspace", "tmp", "latest-download.jpeg")

    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
        },
      },
    } satisfies OpenClawConfig

    await expect(
      inlineChannelPlugin.outbound.sendMedia?.({
        cfg,
        to: "chat:7",
        text: "caption",
        mediaUrl: mediaPath,
        accountId: "default",
      } as any),
    ).rejects.toThrow("not under an allowed directory")

    expect(loadWebMedia).toHaveBeenCalledTimes(1)
    expect(loadWebMedia).toHaveBeenCalledWith(mediaPath, expect.any(Number))
    expect(uploadFile).not.toHaveBeenCalled()
    expect(sendMessage).not.toHaveBeenCalled()
    expect(close).toHaveBeenCalled()
  })

  it("outbound sendMedia forwards media access to the loader", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const uploadFile = vi.fn(async () => ({ fileUniqueId: "INP_1", photoId: 101n }))
    const sendMessage = vi.fn(async () => ({ messageId: 55n }))
    const close = vi.fn(async () => {})
    const mediaReadFile = vi.fn(async () => Buffer.from([1, 2, 3]))
    const loadWebMedia = vi.fn(async () => ({
      buffer: Buffer.from([1, 2, 3]),
      contentType: "image/jpeg",
      kind: "image",
      fileName: "latest-download.jpeg",
    }))

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        uploadFile = uploadFile
        sendMessage = sendMessage
        close = close
      },
    })

    mockOpenClawMediaSdk({
      loadWebMedia,
      detectMime: vi.fn(async () => "image/jpeg"),
    })

    await setInlineTestRuntime({
      loadWebMedia,
      detectMime: vi.fn(async () => "image/jpeg"),
    })

    const { inlineChannelPlugin } = await import("./channel")

    const mediaPath = path.join(os.homedir(), ".openclaw", "workspace", "tmp", "latest-download.jpeg")

    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
        },
      },
    } satisfies OpenClawConfig

    await inlineChannelPlugin.outbound.sendMedia?.({
      cfg,
      to: "chat:7",
      text: "caption",
      mediaUrl: mediaPath,
      accountId: "default",
      mediaAccess: {
        localRoots: [path.dirname(mediaPath)],
        readFile: mediaReadFile,
      },
    } as any)

    expect(loadWebMedia).toHaveBeenCalledWith(
      mediaPath,
      expect.objectContaining({
        maxBytes: 300 * 1024 * 1024,
        localRoots: [path.dirname(mediaPath)],
        readFile: mediaReadFile,
        hostReadCapability: true,
      }),
    )
    expect(uploadFile).toHaveBeenCalledWith(
      expect.objectContaining({
        type: "photo",
      }),
    )
    expect(sendMessage).toHaveBeenCalled()
    expect(close).toHaveBeenCalled()
  })

  it("outbound sendPayload sends multi-media replies and routes thread payloads", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const uploadFile = vi.fn(async () => ({ fileUniqueId: "INP_1", photoId: 101n }))
    const sendMessage = vi.fn(async () => ({ messageId: 55n }))
    const close = vi.fn(async () => {})

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        uploadFile = uploadFile
        sendMessage = sendMessage
        close = close
      },
    })

    mockOpenClawMediaSdk({
      loadWebMedia: vi.fn(async () => ({
        buffer: Buffer.from([1, 2, 3]),
        contentType: "image/png",
        kind: "image",
        fileName: "image.png",
      })),
      detectMime: vi.fn(async () => "image/png"),
    })

    await setInlineTestRuntime({
      loadWebMedia: vi.fn(async () => ({
        buffer: Buffer.from([1, 2, 3]),
        contentType: "image/png",
        kind: "image",
        fileName: "image.png",
      })),
      detectMime: vi.fn(async () => "image/png"),
    })

    const { inlineChannelPlugin } = await import("./channel")

    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
          parseMarkdown: true,
          capabilities: {
            replyThreads: true,
          },
        },
      },
    } satisfies OpenClawConfig

    await inlineChannelPlugin.outbound.sendPayload?.({
      cfg,
      to: "chat:7",
      payload: {
        text: "caption",
        mediaUrls: ["https://example.com/1.png", "https://example.com/2.png"],
      },
      replyToId: "9",
      threadId: "8",
      accountId: "default",
    } as any)

    expect(sendMessage).toHaveBeenNthCalledWith(
      1,
      expect.objectContaining({
        chatId: 8n,
        text: "caption",
        replyToMsgId: 9n,
        parseMarkdown: true,
      }),
    )
    expect(sendMessage).toHaveBeenNthCalledWith(
      2,
      expect.objectContaining({
        chatId: 8n,
      }),
    )
    const secondCall = sendMessage.mock.calls[1]?.[0]
    expect(secondCall?.replyToMsgId).toBeUndefined()
    expect(secondCall?.parseMarkdown).toBeUndefined()
  })

  it("outbound sendPayload maps presentation buttons to Inline actions", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const sendMessage = vi.fn(async () => ({ messageId: 56n }))
    const close = vi.fn(async () => {})

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        sendMessage = sendMessage
        close = close
      },
    })

    await setInlineTestRuntime()

    const { inlineChannelPlugin } = await import("./channel")

    const rendered = await inlineChannelPlugin.outbound.renderPresentation?.({
      payload: {},
      presentation: {
        blocks: [
          { type: "text", text: "Approve deploy?" },
          { type: "buttons", buttons: [{ label: "Approve", value: "approve" }] },
        ],
      },
      ctx: {} as any,
    } as any)

    await inlineChannelPlugin.outbound.sendPayload?.({
      cfg: {
        channels: {
          inline: {
            token: "token",
            baseUrl: "https://api.inline.chat",
            parseMarkdown: true,
          },
        },
      } satisfies OpenClawConfig,
      to: "chat:7",
      payload: rendered,
      accountId: "default",
    } as any)

    const firstArg = sendMessage.mock.calls[0]?.[0]
    expect(firstArg).toEqual(
      expect.objectContaining({
        chatId: 7n,
        text: expect.stringContaining("Approve deploy?"),
        parseMarkdown: true,
      }),
    )
    expect(firstArg?.actions?.rows?.[0]?.actions?.[0]?.text).toBe("Approve")
    const callbackData = firstArg?.actions?.rows?.[0]?.actions?.[0]?.action.callback.data
    expect(Buffer.from(callbackData).toString()).toBe("approve")
  })

  it("outbound sendPayload uses interactive labels as fallback text", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const sendMessage = vi.fn(async () => ({ messageId: 57n }))
    const close = vi.fn(async () => {})

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        sendMessage = sendMessage
        close = close
      },
    })

    await setInlineTestRuntime()

    const { inlineChannelPlugin } = await import("./channel")

    await inlineChannelPlugin.outbound.sendPayload?.({
      cfg: {
        channels: {
          inline: {
            token: "token",
            baseUrl: "https://api.inline.chat",
            parseMarkdown: true,
          },
        },
      } satisfies OpenClawConfig,
      to: "chat:7",
      payload: {
        interactive: {
          blocks: [
            { type: "buttons", buttons: [{ label: "Approve", value: "approve" }] },
          ],
        },
      },
      accountId: "default",
    } as any)

    const firstArg = sendMessage.mock.calls[0]?.[0]
    expect(firstArg).toEqual(
      expect.objectContaining({
        chatId: 7n,
        text: "- Approve",
        parseMarkdown: true,
      }),
    )
    expect(firstArg?.actions?.rows?.[0]?.actions?.[0]?.text).toBe("Approve")
  })

  it("directory and resolver use inline getChats/getChatParticipants", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const invokeRaw = vi.fn(async (method: number) => {
      if (method === 1) {
        return {
          oneofKind: "getMe",
          getMe: {
            user: { id: 777n, firstName: "Inline", username: "inline-bot" },
          },
        }
      }
      if (method === 17) {
        return {
          oneofKind: "getChats",
          getChats: {
            chats: [
              {
                id: 7n,
                title: "General",
                peerId: { type: { oneofKind: "chat", chat: { chatId: 7n } } },
              },
            ],
            dialogs: [{ chatId: 7n, unreadCount: 2 }],
            users: [{ id: 42n, firstName: "Mo", username: "morajabi" }],
            spaces: [],
            messages: [],
          },
        }
      }
      if (method === 13) {
        return {
          oneofKind: "getChatParticipants",
          getChatParticipants: {
            participants: [{ userId: 42n, date: 1_700_000_000n }],
            users: [{ id: 42n, firstName: "Mo", username: "morajabi" }],
          },
        }
      }
      throw new Error(`unexpected method ${String(method)}`)
    })

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
        invokeRaw = invokeRaw
      },
    })

    const runtimeMod = await import("../runtime")
    runtimeMod.setInlineRuntime({
      version: "test",
      state: { resolveStateDir: () => "/tmp" },
      channel: { text: { chunkMarkdownText: (t: string) => [t] } },
    } as unknown as PluginRuntime)

    const { inlineChannelPlugin } = await import("./channel")

    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
        },
      },
    } satisfies OpenClawConfig

    const self = await inlineChannelPlugin.directory?.self?.({
      cfg,
      accountId: "default",
      runtime: {} as any,
    } as any)
    expect(self?.id).toBe("777")

    const peers = await inlineChannelPlugin.directory?.listPeers?.({
      cfg,
      accountId: "default",
      query: "mor",
      limit: 10,
      runtime: {} as any,
    } as any)
    expect(peers?.[0]?.id).toBe("user:42")

    const groups = await inlineChannelPlugin.directory?.listGroups?.({
      cfg,
      accountId: "default",
      query: "gene",
      limit: 10,
      runtime: {} as any,
    } as any)
    expect(groups?.[0]?.id).toBe("7")

    const members = await inlineChannelPlugin.directory?.listGroupMembers?.({
      cfg,
      accountId: "default",
      groupId: "7",
      limit: 10,
      runtime: {} as any,
    } as any)
    expect(members?.[0]?.id).toBe("user:42")

    const resolvedUser = await inlineChannelPlugin.resolver?.resolveTargets?.({
      cfg,
      accountId: "default",
      inputs: ["@morajabi"],
      kind: "user",
      runtime: {} as any,
    } as any)
    expect(resolvedUser?.[0]).toEqual(
      expect.objectContaining({
        resolved: true,
        id: "user:42",
      }),
    )

    const resolvedGroup = await inlineChannelPlugin.resolver?.resolveTargets?.({
      cfg,
      accountId: "default",
      inputs: ["General"],
      kind: "group",
      runtime: {} as any,
    } as any)
    expect(resolvedGroup?.[0]).toEqual(
      expect.objectContaining({
        resolved: true,
        id: "7",
      }),
    )

    const allowlistNames = await inlineChannelPlugin.allowlist?.resolveNames?.({
      cfg,
      accountId: "default",
      scope: "dm",
      entries: ["42", "user:42", "inline:user:42", "inline:user:404", "accessGroup:ops", "*"],
    })
    expect(allowlistNames).toEqual([
      { input: "42", resolved: true, name: "Mo @morajabi" },
      { input: "user:42", resolved: true, name: "Mo @morajabi" },
      { input: "inline:user:42", resolved: true, name: "Mo @morajabi" },
      { input: "inline:user:404", resolved: false },
      { input: "accessGroup:ops", resolved: false },
      { input: "*", resolved: false },
    ])

    const groupAllowlistNames = await inlineChannelPlugin.allowlist?.resolveNames?.({
      cfg,
      accountId: "default",
      scope: "group",
      entries: ["inline:42"],
    })
    expect(groupAllowlistNames).toEqual([
      { input: "inline:42", resolved: true, name: "Mo @morajabi" },
    ])

    expect(invokeRaw).toHaveBeenCalledWith(
      17,
      expect.objectContaining({ oneofKind: "getChats" }),
    )
    expect(invokeRaw).toHaveBeenCalledWith(
      13,
      expect.objectContaining({ oneofKind: "getChatParticipants" }),
    )
  })

  it("pairing notifyApproval supports inline:/user:/raw ids and sends using userId", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const sendMessage = vi.fn(async () => ({ messageId: null }))
    const close = vi.fn(async () => {})

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        sendMessage = sendMessage
        close = close
      },
    })

    const runtimeMod = await import("../runtime")
    runtimeMod.setInlineRuntime({
      version: "test",
      state: { resolveStateDir: () => "/tmp" },
      channel: { text: { chunkMarkdownText: (t: string) => [t] } },
    } as unknown as PluginRuntime)

    const { inlineChannelPlugin } = await import("./channel")

    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
        },
      },
    } satisfies OpenClawConfig

    await inlineChannelPlugin.pairing?.notifyApproval?.({ cfg, id: "inline:42" } as any)
    await inlineChannelPlugin.pairing?.notifyApproval?.({ cfg, id: "user:42" } as any)
    await inlineChannelPlugin.pairing?.notifyApproval?.({ cfg, id: "42" } as any)

    expect(sendMessage).toHaveBeenNthCalledWith(
      1,
      expect.objectContaining({ userId: 42n, text: expect.any(String) }),
    )
    expect(sendMessage).toHaveBeenNthCalledWith(
      2,
      expect.objectContaining({ userId: 42n, text: expect.any(String) }),
    )
    expect(sendMessage).toHaveBeenNthCalledWith(
      3,
      expect.objectContaining({ userId: 42n, text: expect.any(String) }),
    )
    expect(connect).toHaveBeenCalled()
    expect(close).toHaveBeenCalled()
  })
})
