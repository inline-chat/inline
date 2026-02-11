import {
  DmPolicySchema,
  GroupPolicySchema,
  requireOpenAllowFrom,
} from "openclaw/plugin-sdk"
import { z } from "zod"

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
    requireMention: z.boolean().optional(),
    parseMarkdown: z.boolean().optional(),
    textChunkLimit: z.number().int().positive().optional(),
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
