import { z } from "zod"
import {
  BlockStreamingCoalesceSchema,
  DmPolicySchema,
  GroupPolicySchema,
  ToolPolicySchema,
  requireOpenAllowFrom,
} from "../openclaw-compat.js"

const SecretRefSchema = z
  .object({
    source: z.enum(["env", "file", "exec"]),
    provider: z.string(),
    id: z.string(),
  })
  .strict()
const SecretInputSchema = z.union([z.string(), SecretRefSchema])

const InlineActionsSchema = z
  .object({
    send: z.boolean().optional(),
    reply: z.boolean().optional(),
    reactions: z.boolean().optional(),
    read: z.boolean().optional(),
    search: z.boolean().optional(),
    edit: z.boolean().optional(),
    channels: z.boolean().optional(),
    participants: z.boolean().optional(),
    delete: z.boolean().optional(),
    pins: z.boolean().optional(),
    permissions: z.boolean().optional(),
  })
  .strict()

const InlineCapabilitiesSchema = z
  .object({
    replyThreads: z.boolean().optional(),
  })
  .strict()
export const InlineReplyThreadModeSchema = z.enum(["auto", "thread", "main"])
export type InlineReplyThreadMode = z.infer<typeof InlineReplyThreadModeSchema>

const InlineTargetSchema = z.union([z.string(), z.number()])
const InlineAllowEntrySchema = z.union([z.string(), z.number()])

const InlineGroupSchema = z
  .object({
    requireMention: z.boolean().optional(),
    replyThreadMode: InlineReplyThreadModeSchema.optional(),
    replyThreadAutoCreateMinMessages: z.number().int().min(0).optional(),
    replyThreadRequireExplicitMention: z.boolean().optional(),
    replyThreadParentHistoryLimit: z.number().int().min(0).optional(),
    allowFrom: z.array(InlineAllowEntrySchema).optional(),
    systemPrompt: z.string().optional(),
    tools: ToolPolicySchema.optional(),
    toolsBySender: z.record(z.string(), ToolPolicySchema).optional(),
  })
  .strict()

const InlineCommandsSchema = z
  .object({
    native: z.union([z.boolean(), z.literal("auto")]).optional(),
    nativeSkills: z.union([z.boolean(), z.literal("auto")]).optional(),
  })
  .strict()

const InlineExecApprovalsSchema = z
  .object({
    enabled: z.union([z.boolean(), z.literal("auto")]).optional(),
    approvers: z.array(InlineAllowEntrySchema).optional(),
    agentFilter: z.array(z.string()).optional(),
    sessionFilter: z.array(z.string()).optional(),
    target: z.enum(["dm", "channel", "both"]).optional(),
  })
  .strict()
const InlineReactionNotificationsSchema = z.enum(["off", "own", "all", "allowlist"])
const InlineStreamingModeSchema = z.enum(["off", "partial", "block", "progress"])
const InlineStreamingCommandTextSchema = z.enum(["raw", "status"])
const InlineStreamingChunkSchema = z
  .object({
    minChars: z.number().int().positive().optional(),
    maxChars: z.number().int().positive().optional(),
    breakPreference: z.enum(["paragraph", "newline", "sentence"]).optional(),
  })
  .strict()
const InlineStreamingSchema = z.union([
  z.boolean(),
  InlineStreamingModeSchema,
  z
    .object({
      mode: InlineStreamingModeSchema.optional(),
      chunkMode: z.enum(["length", "newline"]).optional(),
      preview: z
        .object({
          chunk: InlineStreamingChunkSchema.optional(),
          toolProgress: z.boolean().optional(),
          commandText: InlineStreamingCommandTextSchema.optional(),
        })
        .strict()
        .optional(),
      progress: z
        .object({
          label: z.union([z.string(), z.literal(false)]).optional(),
          labels: z.array(z.string()).optional(),
          maxLines: z.number().int().positive().optional(),
          render: z.enum(["text", "rich"]).optional(),
          toolProgress: z.boolean().optional(),
          commandText: InlineStreamingCommandTextSchema.optional(),
        })
        .strict()
        .optional(),
      block: z
        .object({
          enabled: z.boolean().optional(),
          coalesce: BlockStreamingCoalesceSchema.optional(),
        })
        .strict()
        .optional(),
    })
    .strict(),
])
const InlineRuntimeStreamingChunkSchema = InlineStreamingChunkSchema.passthrough()
const InlineRuntimeBlockStreamingCoalesceSchema = BlockStreamingCoalesceSchema.passthrough()
const InlineRuntimeStreamingSchema = z.union([
  z.boolean(),
  InlineStreamingModeSchema,
  z
    .object({
      mode: InlineStreamingModeSchema.optional(),
      chunkMode: z.enum(["length", "newline"]).optional(),
      preview: z
        .object({
          chunk: InlineRuntimeStreamingChunkSchema.optional(),
          toolProgress: z.boolean().optional(),
          commandText: InlineStreamingCommandTextSchema.optional(),
        })
        .passthrough()
        .optional(),
      progress: z
        .object({
          label: z.union([z.string(), z.literal(false)]).optional(),
          labels: z.array(z.string()).optional(),
          maxLines: z.number().int().positive().optional(),
          render: z.enum(["text", "rich"]).optional(),
          toolProgress: z.boolean().optional(),
          commandText: InlineStreamingCommandTextSchema.optional(),
        })
        .passthrough()
        .optional(),
      block: z
        .object({
          enabled: z.boolean().optional(),
          coalesce: InlineRuntimeBlockStreamingCoalesceSchema.optional(),
        })
        .passthrough()
        .optional(),
    })
    .passthrough(),
])

export const InlineAccountSchemaBase = z
  .object({
    name: z.string().optional(),
    enabled: z.boolean().optional(),
    baseUrl: z.string().optional(),
    token: SecretInputSchema.optional(),
    tokenFile: z.string().optional(),
    capabilities: InlineCapabilitiesSchema.optional(),
    dmPolicy: DmPolicySchema.optional().default("pairing"),
    allowFrom: z.array(InlineAllowEntrySchema).optional(),
    defaultTo: InlineTargetSchema.optional(),
    systemPrompt: z.string().optional(),
    groupAllowFrom: z.array(InlineAllowEntrySchema).optional(),
    groupPolicy: GroupPolicySchema.optional().default("allowlist"),
    groups: z.record(z.string(), InlineGroupSchema.optional()).optional(),
    requireMention: z.boolean().optional(),
    replyThreadMode: InlineReplyThreadModeSchema.optional(),
    replyThreadAutoCreateMinMessages: z.number().int().min(0).optional(),
    replyThreadRequireExplicitMention: z.boolean().optional(),
    replyThreadParentHistoryLimit: z.number().int().min(0).optional(),
    replyToBotWithoutMention: z.boolean().optional(),
    historyLimit: z.number().int().min(0).optional(),
    dmHistoryLimit: z.number().int().min(0).optional(),
    parseMarkdown: z.boolean().optional(),
    mediaMaxMb: z.number().positive().optional(),
    actions: InlineActionsSchema.optional(),
    reactionNotifications: InlineReactionNotificationsSchema.optional(),
    reactionAllowlist: z.array(InlineAllowEntrySchema).optional(),
    textChunkLimit: z.number().int().positive().optional(),
    chunkMode: z.enum(["length", "newline"]).optional(),
    streaming: InlineStreamingSchema.optional(),
    streamMode: InlineStreamingModeSchema.optional(),
    draftChunk: InlineStreamingChunkSchema.optional(),
    blockStreaming: z.boolean().optional(),
    streamViaEditMessage: z.boolean().optional(),
    blockStreamingCoalesce: BlockStreamingCoalesceSchema.optional(),
    commands: InlineCommandsSchema.optional(),
    execApprovals: InlineExecApprovalsSchema.optional(),
  })
  .strict()

export const InlineAccountSchema = InlineAccountSchemaBase.superRefine((value, ctx) => {
  requireOpenAllowFrom({
    policy: value.dmPolicy,
    ...(value.allowFrom ? { allowFrom: value.allowFrom } : {}),
    ctx,
    path: ["allowFrom"],
    message:
      'channels.inline.dmPolicy="open" requires channels.inline.allowFrom to include "*"',
  })
})

const InlineConfigAccountSchema = InlineAccountSchemaBase.extend({
  streaming: InlineRuntimeStreamingSchema.optional(),
})
  .passthrough()
  .superRefine((value, ctx) => {
    requireOpenAllowFrom({
      policy: value.dmPolicy,
      ...(value.allowFrom ? { allowFrom: value.allowFrom } : {}),
      ctx,
      path: ["allowFrom"],
      message:
        'channels.inline.accounts.*.dmPolicy="open" requires allowFrom to include "*"',
    })
  })

export const InlineRuntimeAccountSchema = InlineAccountSchemaBase.extend({
  streaming: InlineRuntimeStreamingSchema.optional(),
}).passthrough()

export const InlineRuntimeConfigSchema = InlineRuntimeAccountSchema.extend({
  accounts: z.record(z.string(), InlineRuntimeAccountSchema.optional()).optional(),
}).passthrough()

export const InlineConfigSchema = InlineAccountSchemaBase.extend({
  streaming: InlineRuntimeStreamingSchema.optional(),
  accounts: z.record(z.string(), InlineConfigAccountSchema.optional()).optional(),
})
  .passthrough()
  .superRefine((value, ctx) => {
    requireOpenAllowFrom({
      policy: value.dmPolicy,
      ...(value.allowFrom ? { allowFrom: value.allowFrom } : {}),
      ctx,
      path: ["allowFrom"],
      message:
        'channels.inline.dmPolicy="open" requires channels.inline.allowFrom to include "*"',
    })
  })

export type InlineConfig = z.infer<typeof InlineConfigSchema>
export type InlineAccountConfig = z.infer<typeof InlineAccountSchema>
export type InlineRuntimeConfig = z.infer<typeof InlineRuntimeConfigSchema>
