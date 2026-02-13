import {
  BlockStreamingCoalesceSchema,
  DmPolicySchema,
  GroupPolicySchema,
  ToolPolicySchema,
  requireOpenAllowFrom,
} from "openclaw/plugin-sdk"
import { z } from "zod"

const InlineActionsSchema = z
  .object({
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

const InlineGroupSchema = z
  .object({
    requireMention: z.boolean().optional(),
    tools: ToolPolicySchema,
    toolsBySender: z.record(z.string(), ToolPolicySchema).optional(),
  })
  .strict()

export const InlineAccountSchemaBase = z
  .object({
    name: z.string().optional(),
    enabled: z.boolean().optional(),
    baseUrl: z.string().optional(),
    token: z.string().optional(),
    tokenFile: z.string().optional(),
    dmPolicy: DmPolicySchema.optional().default("pairing"),
    allowFrom: z.array(z.string()).optional(),
    groupAllowFrom: z.array(z.string()).optional(),
    groupPolicy: GroupPolicySchema.optional().default("allowlist"),
    groups: z.record(z.string(), InlineGroupSchema.optional()).optional(),
    requireMention: z.boolean().optional(),
    replyToBotWithoutMention: z.boolean().optional(),
    historyLimit: z.number().int().min(0).optional(),
    dmHistoryLimit: z.number().int().min(0).optional(),
    parseMarkdown: z.boolean().optional(),
    mediaMaxMb: z.number().positive().optional(),
    actions: InlineActionsSchema.optional(),
    textChunkLimit: z.number().int().positive().optional(),
    chunkMode: z.enum(["length", "newline"]).optional(),
    blockStreaming: z.boolean().optional(),
    blockStreamingCoalesce: BlockStreamingCoalesceSchema.optional(),
  })
  .strict()

export const InlineRuntimeAccountSchema = InlineAccountSchemaBase.passthrough()

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

export const InlineRuntimeConfigSchema = InlineRuntimeAccountSchema.extend({
  accounts: z.record(z.string(), InlineRuntimeAccountSchema.optional()).optional(),
}).passthrough()

export const InlineConfigSchema = InlineAccountSchemaBase.extend({
  accounts: z.record(z.string(), InlineAccountSchema.optional()).optional(),
}).superRefine((value, ctx) => {
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
